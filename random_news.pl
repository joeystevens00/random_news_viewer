use strict;
use warnings;
#  perlbrew use perl-5.29.0@randomNews

use Mojolicious::Lite;
use Mojo::UserAgent;
use JSON;
use Try::Tiny;
use Redis;
use Data::Dumper;
use Mojo::IOLoop;
use Mojo::Log;
use Mojo::File;
use Carp;
use Math::Random::Secure 'irand';


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
our $REDIS = Redis->new(host=>$config->{app}->{redis_host}, onconnect=>sub {
  $log->debug("Redis connected " . $config->{app}->{redis_host});
});
croak "Redis not initialized" unless ref $REDIS eq 'Redis';

$log->debug("Categories : " . Dumper($CATEGORIES));

warm_caches();
$log->debug("Initializing cache warmer");
init_cache_warmer();

sub init_cache_warmer {
  my $cache_warm_rate = $config->{app}->{cache_warm_rate};
  my $loop = Mojo::IOLoop->singleton;
  $loop->recurring( $cache_warm_rate => sub {
    my $loop = shift;
    warm_caches();
  });
}

sub get_config {
  try {
    decode_json (Mojo::File->new("config.json")->slurp)
  }
  catch {
    warn($_);
    undef;
  };
}

sub add_category {
  my $category = shift;
  my $topic_name = shift;
  $CATEGORIES->{$category} = [] unless ref $CATEGORIES->{$category} eq 'ARRAY';
  push @{$CATEGORIES->{$category}}, $topic_name;
}

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

# request_everything
# for everything calls attempts to request until an error
# NOTE: With developer accounts will request the first 1000 entries then see an error and stop
# Without production account presumably would request until no results left then see an error and stop
sub request_everything {
  my $url = shift;
  my $compiling_results = 1;
  my $compiled_results = {articles=>[]};
  my $page = 1;
  while($compiling_results) {
    my $results = request($url . "&page=$page&language=en");

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
    my $total_results = $results->{totalResults};
    $compiled_results->{totalResults} = $total_results unless defined $compiled_results->{totalResults};
    push @{$compiled_results->{articles}}, @{$results->{articles}} if ref $results->{articles} eq 'ARRAY';
    $page++;
  }
  $compiled_results;
}

sub warm_cache {
  my ($topic_name, $json) = @_;
  $log->debug("Warming cache: $topic_name");

  unless(ref $json eq 'HASH') {
    $json = $REQUEST_FUNCTIONS->{$topic_name}->();
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

sub fetch_cache {
  my $cache_name = shift;
  my $cache = try { decode_json ($REDIS->get("cache:$cache_name")) }
  catch {
    #$log->warn($_);
    undef
  };

  # Debug info
  if(defined $cache && ref $cache eq 'HASH') {
    my $cache_size = ref $cache->{articles} eq 'ARRAY' ? scalar @{$cache->{articles}} : 0;
    $log->debug("Fetch Cache found $cache_name has $cache_size articles");
  }
  $cache;
}

# warm_caches
# warms all of the caches if they need it
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

get '/proxy_random_article' => sub {
  my $c = shift;
  $c->render_later;
  my $topic_name = $c->param('type');
  $UA->get("http://localhost:3000/random_article?type=$topic_name" => sub {
    my $user_a = shift;
    my $tx = shift;
    my $article_link = $tx->result->body;
    $log->debug("article_link $article_link");
    my $article_content = try { $UA->get($article_link)->result->body } catch {$log->warn($_); undef};
    $c->render(text => $article_content);
  });
};

get '/random_article' => sub {
  my $c   = shift;
  my $topic_name = $c->param('type');
  my $category;
  # Random category option
  if($topic_name eq 'random') {
    my @all_categories = keys %$CATEGORIES;
    my $random_category = @all_categories[irand(@all_categories)];
    $topic_name = $random_category;
  }
  # Random article from Category
  if($topic_name && ref $CATEGORIES->{$topic_name} eq 'ARRAY') {
    $category=$topic_name;
    my @category_entries = @{$CATEGORIES->{$category}};
    my $random_cache_name_in_category = @category_entries[irand(@category_entries)];
    $topic_name = $random_cache_name_in_category;
  }
  my $cache = fetch_cache($topic_name || 'top_headlines');
  my $random_article = @{$cache->{articles}}[ irand(@{$cache->{articles}}) ];
  my $random_url = $random_article->{url};
  $log->debug("$topic_name : $random_url" . ($category ? " Category: $category" : ""));

  $c->render(text => $random_url);
};
 app->start;
