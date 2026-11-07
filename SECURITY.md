# Security policy

## Reporting a vulnerability

Please report privately, not in a public issue: open the repository's **Security** tab and choose
**Report a vulnerability** (GitHub private vulnerability reporting). This covers V2Mac, the Secure
Sandbox (`v2mac-sandbox`), its plugin store (`v2mac-store`) and NoLeaker.

Include what you saw, the version, and the steps to reproduce. Leave out your subscription links and
server details: we never need them.

We aim to answer within a week. A fix ships as a normal signed release, with a GitHub security advisory
once most users can update.

## Supported versions

Only the latest release of each project gets security fixes. V2Mac updates itself in-app; the sandbox
and its plugins follow the newest signed release.

## What counts

Anything that sends traffic around the tunnel when V2Mac says it is protected, lets a page or plugin
leave the sandbox, makes V2Mac install an update, core or plugin that was not signed by us, or exposes
server configs, keys or the local API to another user or app. Known limits are listed in the wiki's
Known Limitations page and are not vulnerabilities unless the code does worse than that page says.
