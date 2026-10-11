// Sends a Reddit page that was opened in Safari on to the Reddit app.
//
// A sideloaded app cannot claim reddit.com links (that needs a signature from
// Reddit), so they open in Safari. The app does answer to "reddit://" links,
// and Safari asks before following one.
(function () {
  if (window.top !== window) return; // not in embedded frames

  // Only for pages reached from elsewhere (a link in another app, a search
  // result, the address bar), so that browsing Reddit in Safari stays possible.
  let from = "";
  try {
    from = new URL(document.referrer).hostname;
  } catch (error) {}
  if (from === "reddit.com" || from.endsWith(".reddit.com")) return;

  let path = location.pathname;
  if (location.hostname === "redd.it") {
    path = "/comments" + path; // short link: redd.it/<post id>
  } else if (!/^\/(r|u|user|comments|gallery|search)(\/|$)/.test(path)) {
    return; // login, settings, help and the like stay in Safari
  }

  // Once per tab: after "Cancel", reloading the page must not ask again.
  try {
    if (sessionStorage.getItem("openInRedditAsked")) return;
    sessionStorage.setItem("openInRedditAsked", "1");
  } catch (error) {}

  location.replace("reddit://reddit" + path + location.search + location.hash);
})();
