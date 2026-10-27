# tomd

Web pages → Markdown, plus a CORS passthrough, for an **allowlist** of sites.
First (and so far only) site: Nim forum threads. Runs at
**tomd.pietroppeter.xyz** (deployed with [Disco](https://disco.cloud)).

## Usage

Put tomd's address in front of a URL (the scheme is optional):

```
https://tomd.pietroppeter.xyz/https://forum.nim-lang.org/t/12345
https://tomd.pietroppeter.xyz/forum.nim-lang.org/t/12345
```

| Route | What |
|---|---|
| `GET /` | page: paste a URL, copy the Markdown |
| `GET /<url>` | Markdown for `<url>` (`text/markdown`) |
| `GET /md?url=<url>` | same, URL as a query parameter |
| `GET /cors/<url>` | raw response with `Access-Control-Allow-Origin: *` |
| `GET /healthz` | `ok` |

## Nim forum converter

`src/tomd/nimforum.nim` calls nimforum's own JSON API server-side (see
[nim-lang/nimforum `src/forum.nim`](https://github.com/nim-lang/nimforum/blob/master/src/forum.nim));
it does not go through `/cors/`:

- `/posts.json?id=<thread>`: thread and posts. Only the first and last 10 posts
  are full; the ids of the ones in between are in each post's `moreBefore`.
- `/specific_posts.json?ids=[..]`: fills that gap.
- `/post.rst?id=<post>`: raw source of the latest revision (RST with Markdown
  support), used for post bodies.

It works on its own as a CLI too:

```sh
nim c -d:release -d:ssl -o:bin/nimforum src/tomd/nimforum.nim
./bin/nimforum https://forum.nim-lang.org/t/12345 -o:thread.md   # --html for rendered bodies
```

## Run / deploy

```sh
nim c -d:release -d:ssl -o:bin/tomd src/tomd.nim && PORT=8000 ./bin/tomd
```

Disco: `Dockerfile` + `disco.json` (port 8000). `FORUM_BASE` overrides where
forum data is fetched from (for tests).

## Adding a site

Write a module with `canonical(u: Uri): string` (validate and normalize the URL,
used as the cache key; raise `ValueError` if unsupported) and
`render(canon: string): Future[string]`, then add it to `Converters` in
`src/tomd.nim`. The host is then allowlisted for both Markdown and `/cors/`.

## Guard rails

Not an open proxy: every outgoing request goes to an allowlisted host. Plus:
GET only, per-IP rate limit (20/min, from `X-Forwarded-For` as set by Disco's
Caddy), at most 4 uncached conversions in flight, a 10-minute cache (which also
keeps nimforum view counts from being inflated, since `posts.json` counts a
view), and a 5 MB cap on passthrough responses.

## Why the page has no CORS problem

The page and the API share one origin, so the browser never makes a
cross-origin request. The `Access-Control-Allow-Origin: *` headers are for
*other* pages (e.g. static sites) calling tomd.
