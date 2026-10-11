# RedditSideloadFix

Makes the Reddit app work when it is installed under a different bundle ID and team (SideStore, AltStore): keychain access group, app group container and the bundle ID sent to reCAPTCHA are presented as the original ones.

Copied from [level3tjg/RedditSideloadFix](https://github.com/level3tjg/RedditSideloadFix) at commit `161b2cb`, plus fixes for startup crashes when the keychain is unavailable or a method is added without a type string. MIT, see [LICENSE](LICENSE).

`fishhook/` is [facebook/fishhook](https://github.com/facebook/fishhook) at commit `aadc161`, BSD, see [fishhook/LICENSE](fishhook/LICENSE).
