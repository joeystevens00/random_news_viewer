use strict;
use warnings;
#  perlbrew use perl-5.29.0@randomNews

use Mojolicious::Lite;
use Mojo::UserAgent;
use JSON;
use Try::Tiny;
use Redis;
use Data::Dumper;
use Mojo::Collection;
use Mojo::IOLoop;
use Mojo::Log;
use Mojo::File;
use Carp;
use Math::Random::Secure 'irand';
use Time::Piece;
use Time::Seconds;

# Load Config
our $REQUEST_FUNCTIONS = {};
our @TOPICS;
our $CATEGORIES = {}; #  { cat1 => [ topic1, topic2 ] }

our $config = get_config();
croak "Unable to get config" unless ref $config eq 'HASH';
parse_topics(); # Set $REQUEST_FUNCTIONS and @TOPICS

our $log = Mojo::Log->new(level=>$config->{app}->{log_level});
our $API_KEY = $config->{app}->{news_api_key};
our $NEWS_API_ENDPOINT = 'https://newsapi.org/v2/';
our $UA = Mojo::UserAgent->new;
our $AUTH = "&apiKey=$API_KEY";
our $REQUEST_PAGE_SIZE = $config->{app}->{request_page_size};
our $DEFAULT_REQUEST_OPTIONS = "&pageSize=$REQUEST_PAGE_SIZE"; # For all requests
our $KNOWN_EMPTY_CACHES = {}; # Provides a cooldown for caches that are known to be empty to prevent selecting them multiple times in a row

our $REDIS = Redis->new(host=>$config->{app}->{redis_host}, onconnect=>sub {
  $log->debug("Redis connected " . $config->{app}->{redis_host});
});
croak "Redis not initialized" unless ref $REDIS eq 'Redis';

$log->debug("Categories : " . Dumper($CATEGORIES));

warm_caches();
$log->debug("Initializing cache warmer");
init_cache_warmer();

# init_cache_warmer
# starts up recurring task for warming the cache
sub init_cache_warmer {
  my $cache_warm_rate = $config->{app}->{cache_warm_rate};
  my $loop = Mojo::IOLoop->singleton;
  $loop->recurring( $cache_warm_rate => sub {
    my $loop = shift;
    warm_caches();
  });
}

# get_config
# returns HashRef representation of config.json
sub get_config {
  try {
    decode_json (Mojo::File->new("config.json")->slurp)
  }
  catch {
    warn($_);
    undef;
  };
}

# add_category($category, $topic_name)
# associates $topic to $category  in $CATEGORIES
sub add_category {
  my $category = shift;
  my $topic_name = shift;
  $CATEGORIES->{$category} = [] unless ref $CATEGORIES->{$category} eq 'ARRAY';
  push @{$CATEGORIES->{$category}}, $topic_name;
}

# parse_topics
# iterates over topics in config and sets up fetch routines for each of them in $REQUEST_FUNCTIONS
# also categorizes the topics based on category and categories
sub parse_topics {
  my $topics = $config->{topics};
  foreach my $topic_name (keys %$topics) {
    my $topic = $topics->{$topic_name};

    # categories
    if (defined $topic->{category}) {
      add_category($topic->{category}, $topic_name)
    }
    if(ref $topic->{categories} eq 'ARRAY') {
      add_category($_, $topic_name) for @{$topic->{categories}};
    }
    push @TOPICS, $topic_name; # Keep a cache for the topic

    # Set fetch routine for topic
    if(defined $topic->{query}) {
      $REQUEST_FUNCTIONS->{$topic_name} = sub {
        request($topic->{query})
      };
    }
    else {
      $REQUEST_FUNCTIONS->{$topic_name} = sub {
        request_everything("everything?q=$topic_name")
      };
    }
  }
}

# request($method, $url)
# makes requests to NewsAPI
# method is optional and defaults to get
sub request {
  my ($method, $url) = (shift, shift);
  unless(defined $url) {
    $url = $method;
    $method = "get";
  }
  my $request_url = $NEWS_API_ENDPOINT . $url . $AUTH . $DEFAULT_REQUEST_OPTIONS;
  $log->debug("$method $request_url");
  try {
    decode_json ($UA->$method($request_url)->result->body);
  }
  catch {
    $log->warn($_);
    undef;
  }
}

# check_all_cache_cooldowns
# iterates over $KNOWN_EMPTY_CACHES and takes $cache_name off cooldown if it's ready for it
sub check_all_cache_cooldowns {
  foreach my $cooldown_cache (keys %$KNOWN_EMPTY_CACHES) {
    if(cache_cooldown_passed($cooldown_cache)) {
      set_cache_cooldown($cooldown_cache, 0); # Take off cooldown
    }
  }
}

# cache_cooldown_passed($cache_name)
# checks if $cache_name is ready to be done with it's cooldown
sub cache_cooldown_passed { time - $KNOWN_EMPTY_CACHES->{(shift)} > $config->{app}->{empty_cache_cooldown_seconds} ? 1 : 0 }

# request_everything
# for everything calls attempts to request until an error
# NOTE: With developer accounts will request the first 1000 entries then see an error and stop
# Without production account presumably would request until no results left then see an error and stop
sub request_everything {
  my $url = shift;
  my $oldest_day_allowed = Time::Piece->new(time - (ONE_DAY*$config->{app}->{days_to_include_everything}))->strftime("%Y-%m-%d");
  my $language = $config->{app}->{language} || "en";
  my $default_options = "&from=$oldest_day_allowed&language=$language";
  my $compiling_results = 1;
  my $compiled_results = {articles=>[]};
  my $page = 1;
  while($compiling_results) {
    my $results = request($url . "&page=$page" . $default_options);

    unless(ref $results eq 'HASH') {
      $log->warn("Results not hashref: " . Dumper($results));
      $compiling_results = 0;
      next;
    }
    if ($results->{status} ne "ok") {
      #$log->warn("Results status not ok: " . Dumper($results));
      $compiling_results = 0;
      next;
    }
    if(cache_size($results) eq 0) {
      $compiling_results = 0;
      next;
    }
    my $total_results = $results->{totalResults};
    $compiled_results->{totalResults} = $total_results unless defined $compiled_results->{totalResults};
    push @{$compiled_results->{articles}}, @{$results->{articles}} if ref $results->{articles} eq 'ARRAY';
    $page++;
  }
  $compiled_results;
}

# warm_cache($topic_name, $json)
# sets cache:$topic_name in redis set to $json (hashref)
# $json is optional and if not provided request function is called $REQUEST_FUNCTIONS->{$topic_name} to populate JSON
sub warm_cache {
  my ($topic_name, $json) = @_;
  $log->debug("Warming cache: $topic_name");

  unless(ref $json eq 'HASH') {
    $json = $REQUEST_FUNCTIONS->{$topic_name}->();
  }
  unless(ref $json eq 'HASH') {
    $log->error("Missing json can't warm cache");
    return 0;
  }

  $json->{refresh_time} = time;
  my $ret = try {
    my $ok = $REDIS->set("cache:$topic_name", (encode_json $json));
    ($ok||"") =~ /OK/ ? 1 : 0
  }
  catch {
    $log->warn($_);
    0;
  };
  $ret;
}

# fetch_cache($topic_name)
# given topic_name returns HashRef representation
# if cache is empty sets it as a known empty cache and checks all known empty caches to see if they've been on cooldown long enough
sub fetch_cache {
  my $cache_name = shift;
  my $cache = try { decode_json ($REDIS->get("cache:$cache_name")) }
  catch {
    #$log->warn($_);
    undef
  };

  # Debug info

  my $cache_size = cache_size($cache);
  $log->debug("Fetch Cache found $cache_name has $cache_size articles");
  check_all_cache_cooldowns();
  if($cache_size eq 0) {
    $log->warn("Fetch Catch detected empty cache. Clearing cache");
    $REDIS->del("cache:$cache_name");
    # If no existing cooldown add one
    if(!defined $KNOWN_EMPTY_CACHES->{$cache_name}) {
      set_cache_cooldown($cache_name, 1); # Put on cooldown
    } # If existing cooldown check it
    elsif (!cache_cooldown_passed($cache_name)) {
      set_cache_cooldown($cache_name, 1); # Put on cooldown
    } # If existing cooldown and cooldown satisifed remove it
    else {
      set_cache_cooldown($cache_name, 0); # Take off cooldown
    }
  }
  else {
    set_cache_cooldown($cache_name, 0); # Take off cooldown
  }

  $cache;
}

# set_cache_cooldown($topic_name, $setValue)
# when 0 removes $topic_name from $KNOWN_EMPTY_CACHES
# when 1 sets $topic_name as $KNOWN_EMPTY_CACHES
sub set_cache_cooldown {
  my ($cache_name, $set) = @_;
  $set = $set ? $set : 0;
  if($set eq 0) {
    if(defined $KNOWN_EMPTY_CACHES->{$cache_name}) {
      $log->debug("Taking $cache_name off cooldown for fetching");
      delete $KNOWN_EMPTY_CACHES->{$cache_name};
    }
  }
  else {
    $log->debug("Putting $cache_name on cooldown for fetching");
    $KNOWN_EMPTY_CACHES->{$cache_name} = time;
  }
}

# cache_size
# given $cache returns number of articles
sub cache_size {
  my $cache = shift;
  if(defined $cache && ref $cache eq 'HASH') {
    my $cache_size = ref $cache->{articles} eq 'ARRAY' ? scalar @{$cache->{articles}} : 0;
    $cache_size
  }
  else {
    0;
  }
}

# warm_caches
# warms all of the caches if they need it
# Config Options:
# cache_warm_rate : Number of seconds that must be exceeded before cache is warmed
sub warm_caches {
  my $cache_warm_rate = $config->{app}->{cache_warm_rate};
  $log->debug("Warm Caches");
  for(@TOPICS) {
    my $cache = fetch_cache($_);
    unless (defined $cache || defined $cache->{refresh_time}) {
      warm_cache($_);
      next;
    }
    if(time - $cache->{refresh_time} > ($cache_warm_rate-1)) {
      warm_cache($_);
    }
  }
}

# random_article
# param options:
# type : name of category or topic or "random" for random category
hook before_routes => sub {
  my $c = shift;
  $c->res->headers->header("Access-Control-Allow-Origin" => "*");
};

# Needs secured
# get '/proxy' => sub {
#   my $c = shift;
#   $c->render_later;
#   #my $topic_name = $c->param('type');
#   my $url = $c->param('url');
#   $UA->get($url => sub {
#     my $user_a = shift;
#     my $tx = shift;
#     my $article_content = $tx->result->body;
#     #$log->debug("article_link $article_link");
#     #my $article_content = try { $UA->get($article_link)->result->body } catch {$log->warn($_); undef};
#     $c->render(text => $article_content);
#   });
# };

# available_categories
# takes optional arrayref or uses $CATEGORIES
# returns all categories which aren't known to be empty
sub available_categories {
  my $opt_categories = shift;
  my @categories_to_search = ref $opt_categories eq 'ARRAY' ? @$opt_categories : keys %$CATEGORIES;
  my $available_categories = Mojo::Collection->new(@categories_to_search)->grep(sub {
    defined $KNOWN_EMPTY_CACHES->{$_} ? 0 : 1
  })->to_array;
  $log->debug("available_categories: " . Dumper($available_categories));
  $available_categories;
}

# topic_to_cache($topic_name, $tries)
# randomly selects topic from either : Metacategory (currently only 'random') or Category if given one
# returns $cache
# Config Options:
# fetch_cache_retry_count : Sets number of $tries to find a topic with a non-empty cache. Defaults to 3
sub topic_to_cache {
  my $topic_name = shift;
  my $tries = shift || 0;
  my $category;
  my $metacategory;
  $log->debug("topic_to_cache($topic_name, $tries)");
  if($topic_name eq 'random') {
    my $deprioritized_categories = $config->{app}->{random_metacategory}->{deprioritized_categories} || [];

    my @all_available_categories = @{available_categories()};
    $metacategory = $topic_name;
    my $random_category = @all_available_categories[irand(@all_available_categories)];
    if(grep { $random_category eq $_ } @$deprioritized_categories) {
      my $suppression_percentage = $config->{app}->{random_metacategory}->{suppression_percentage};
      my $allowed_percentage =  100-($suppression_percentage||0);
      my $suppression_roll = irand(100)+1;
      my $suppressed = $suppression_roll <= $allowed_percentage ? 0 : 1;
      $log->debug("Random Metacategory suppression roll ($suppression_roll) for $random_category | allowed_percentage $allowed_percentage | suppression_percentage $suppression_percentage | suppressed $suppressed");
      if($suppressed) {
        return topic_to_cache($metacategory ? $metacategory : $category);
      }
    }
    $topic_name = $random_category;
  }
  if($topic_name && ref $CATEGORIES->{$topic_name} eq 'ARRAY') {
    $category=$topic_name;
    my @category_entries = @{$CATEGORIES->{$category}};
    my @available_subset_of_categories = @{available_categories(\@category_entries)};
    my $random_topic = @available_subset_of_categories[irand(@available_subset_of_categories)];
    $topic_name = $random_topic;
  }
  my $cache = fetch_cache($topic_name || 'top_headlines');
  my $cache_size = cache_size($cache);
  if($cache_size eq 0) {
    my $allowed_attempts = $config->{app}->{fetch_cache_retry_count} || 3;
    $log->warn("Empty cache requested $topic_name $tries/$allowed_attempts used");
    if($tries >= $allowed_attempts) {
      $log->error("Maximum attempts exceeded($allowed_attempts) for finding cache in " . ($metacategory ? " Metacategory: $metacategory " : "") . ($category ? " Category $category" : ""));
      return (undef, $category);
    }
    if($category) {
      return topic_to_cache($metacategory ? $metacategory : $category, ++$tries);
    }
  }
  $log->debug("return topic_to_cache($cache, $category)");

  return ($cache, $category);
}

get '/' => sub {
  my $c = shift;

  $c->reply->static('client.html');
};

get '/random_article' => sub {
  my $c   = shift;
  my $topic_name = $c->param('type');
  my ($cache, $category) = topic_to_cache($topic_name || "top_headlines");
  unless($cache) {
    return $c->render(text => "No data found for $topic_name : $category");
  }
  my $random_article = @{$cache->{articles}}[ irand(@{$cache->{articles}}) ];
  my $random_url = $random_article->{url};

  $log->debug("$topic_name : $random_url" . ($category ? " Category: $category" : ""));

  $c->render(text => $random_url);
};
app->config(hypnotoad => {listen => ['http://*:3000']});
app->start;
