// ==UserScript==
// @name     Random News
// @version  1
// @grant    none
// ==/UserScript==


function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function random_news(sleep_seconds) {
  await sleep(sleep_seconds || 120000);
  const Http = new XMLHttpRequest();
	const url='http://localhost:3000/random_article?type=random';
	Http.open("GET", url);
	Http.send();
	Http.onreadystatechange=(e)=>{
		console.log(Http.responseText)
    window.location.assign(Http.responseText);

	}
}

window.addEventListener('pageshow', function() {
  console.log(window.location);
	random_news()
});

window.addEventListener("keyup", function(e) {
  if(e.keyCode == 32) { //space
    random_news(10);
   }
  if(e.keyCode == 81) { //q pauses execution
    quit_status = 1;
  }
  if(e.keyCode == 67) { //c continues execution
    quit_status = 0;
    random_news(10);
  }
}); 
