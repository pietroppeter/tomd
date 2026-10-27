## tomd: web pages → Markdown, for an allowlist of sites.
##
##   GET /<url>             Markdown for <url>; scheme optional, e.g.
##                          /https://forum.nim-lang.org/t/12345
##                          /forum.nim-lang.org/t/12345
##                          /scholar.google.com/citations?user=<id>
##   GET /md?url=<url>      same, as a query parameter (used by the page)
##   GET /cors/<url>        raw passthrough with CORS headers (allowlisted hosts only)
##   GET /                  the page: paste a URL, copy the Markdown
##   GET /healthz
##
## Not an open proxy: every fetch goes to a host in `Converters`. Plus a per-IP
## rate limit, an in-flight cap and a cache (which also keeps us from inflating
## nimforum's view counts, since posts.json counts a view).

import std/[asyncdispatch, asynchttpserver, httpclient, strutils, tables,
            times, uri, os, sequtils]
import tomd/[nimforum, scholar]

type Converter* = object
  canonical*: proc (u: Uri): string {.nimcall.}   ## raises ValueError if unsupported
  render*: proc (canon: string): Future[string] {.nimcall, gcsafe.}

const
  Page = staticRead("page.html")
  CacheTtl = initDuration(minutes = 10)
  CacheMax = 500
  RatePerMin = 20
  MaxInFlight = 4
  MaxPassthrough = 5 * 1024 * 1024

let Converters* = {
  nimforum.Host: Converter(canonical: nimforum.canonical, render: nimforum.render),
  scholar.Host: Converter(canonical: scholar.canonical, render: scholar.render),
}.toTable

var
  cache: Table[string, (Time, string)]
  hits: Table[string, (Time, int)]
  inFlight = 0

proc supported(): string =
  {.cast(gcsafe).}: toSeq(Converters.keys).join(", ")

proc isSupported(host: string): bool =
  {.cast(gcsafe).}: host in Converters

proc parseTarget*(raw: string): Uri =
  ## "/https://host/p", "https:/host/p" (collapsed slashes), "host/p" → Uri.
  ## Raises ValueError unless the host is allowlisted.
  var s = raw.strip
  s.removePrefix('/')
  for sch in ["https:/", "http:/"]:
    if s.startsWith(sch) and not s.startsWith(sch & "/"):
      s = sch & "/" & s[sch.len .. ^1]
  if "://" notin s: s = "https://" & s
  result = parseUri(s)
  if not isSupported(result.hostname):
    raise newException(ValueError,
      "host '" & result.hostname & "' is not supported (supported: " & supported() & ")")

proc clientIp(req: Request): string =
  ## Disco puts Caddy in front: trust the first X-Forwarded-For entry.
  let xff = req.headers.getOrDefault("x-forwarded-for")
  if xff.len > 0: xff.split(',')[0].strip else: req.hostname

proc allow(ip: string): bool =
  {.cast(gcsafe).}:
    let now = getTime()
    var (start, n) = hits.getOrDefault(ip, (now, 0))
    if now - start > initDuration(minutes = 1): (start, n) = (now, 0)
    inc n
    hits[ip] = (start, n)
    if hits.len > 10_000: hits.clear()
    result = n <= RatePerMin

proc markdownFor(target: Uri): Future[string] {.async, gcsafe.} =
  {.cast(gcsafe).}:
    let conv = Converters[target.hostname]
    let key = conv.canonical(target)
    let now = getTime()
    if key in cache and now - cache[key][0] < CacheTtl:
      return cache[key][1]
    if inFlight >= MaxInFlight:
      raise newException(ResourceExhaustedError, "busy, try again shortly")
    inc inFlight
    try:
      result = await conv.render(key)
    finally:
      dec inFlight
    if cache.len >= CacheMax: cache.clear()
    cache[key] = (now, result)

proc passthrough(target: Uri): Future[(string, string)] {.async, gcsafe.} =
  ## (content-type, body) of an allowlisted URL, size-capped.
  let c = newAsyncHttpClient(userAgent = UserAgent)
  try:
    let r = await c.get($target)
    if r.code == Http404: raise newException(NotFoundError, $target & " -> " & $r.code)
    if not r.code.is2xx: raise newException(IOError, $target & " -> " & $r.code)
    let body = await r.body
    if body.len > MaxPassthrough: raise newException(IOError, "response too large")
    var ctype: string = r.headers.getOrDefault("content-type")
    if ctype.len == 0: ctype = "application/octet-stream"
    result = (ctype, body)
  finally:
    c.close()

proc handle(req: Request) {.async, gcsafe.} =
  let path = req.url.path
  proc hdrs(ctype: string): HttpHeaders =
    newHttpHeaders({"Access-Control-Allow-Origin": "*", "Content-Type": ctype})
  proc fail(code: HttpCode, msg: string): Future[void] =
    req.respond(code, msg & "\n", hdrs("text/plain; charset=utf-8"))

  if req.reqMethod != HttpGet:
    await fail(Http405, "GET only"); return
  if path in ["/", "/index.html"]:
    await req.respond(Http200, Page,
      newHttpHeaders({"Content-Type": "text/html; charset=utf-8"})); return
  if path == "/healthz":
    await req.respond(Http200, "ok"); return
  if path == "/favicon.ico":
    await req.respond(Http404, ""); return
  if not allow(clientIp(req)):
    await fail(Http429, "rate limited, try again in a minute"); return

  # The target URL: from ?url=, or the rest of the path (+ its query string).
  let isCors = path.startsWith("/cors/")
  var raw: string
  if path == "/md":
    for k, v in decodeQuery(req.url.query):
      if k == "url": raw = v
  else:
    raw = (if isCors: path["/cors".len .. ^1] else: path)
    if req.url.query.len > 0: raw.add "?" & req.url.query

  var target: Uri
  try:
    target = parseTarget(raw)
  except ValueError as e:
    await fail(Http400, e.msg); return

  try:
    if isCors:
      let (ctype, body) = await passthrough(target)
      await req.respond(Http200, body, hdrs(ctype))
    else:
      let md = await markdownFor(target)
      await req.respond(Http200, md, hdrs("text/markdown; charset=utf-8"))
  except ValueError as e:
    await fail(Http400, e.msg)
  except NotFoundError:
    await fail(Http404, "not found: " & $target)
  except ResourceExhaustedError as e:
    await fail(Http503, e.msg)
  except BlockedError as e:
    await fail(Http503, e.msg)
  except CatchableError as e:
    await fail(Http502, "could not fetch " & $target & ": " & e.msg)

when isMainModule:
  let port = getEnv("PORT", "8000").parseInt
  echo "tomd listening on :", port, " (", supported(), ")"
  waitFor newAsyncHttpServer().serve(Port(port), handle)
