## Render a Nim forum thread as Markdown, via nimforum's JSON API.
##
## Endpoints (see nim-lang/nimforum src/forum.nim):
## - `/posts.json?id=<thread>`: thread + posts. Only the first and last 10
##   posts are full; the ids of the ones in between are in `moreBefore`.
## - `/specific_posts.json?ids=[..]`: full posts by id (fills the gap).
## - `/post.rst?id=<post>`: raw source of the latest revision
##   (RST with Markdown support, as typed by the author).
##
## tomd converter for forum.nim-lang.org (`canonical` + `render`), also a CLI:
##   nim c -d:ssl -r src/tomd/nimforum.nim https://forum.nim-lang.org/t/12345 [-o:thread.md] [--html]

import std/[asyncdispatch, httpclient, json, strutils, times, tables,
            algorithm, uri, sequtils, os]

const
  Host* = "forum.nim-lang.org"
  DefaultBase* = "https://" & Host
  UserAgent* = "tomd/0.1 (+https://github.com/pietroppeter/tomd)"

type Getter* = proc (url: string): Future[string] {.gcsafe.}

proc httpGet*(url: string): Future[string] {.async, gcsafe.} =
  let c = newAsyncHttpClient(userAgent = UserAgent)
  try:
    let r = await c.get(url)
    if not r.code.is2xx:
      raise newException(IOError, url & " -> " & $r.code)
    result = await r.body
  finally:
    c.close()

proc parseThreadId*(s: string): int =
  ## Accepts `12345`, `.../t/12345`, `.../t/12345/2#678`.
  var t = s.strip
  let i = t.find("/t/")
  if i >= 0: t = t[i+3 .. ^1]
  var digits = ""
  for c in t:
    if c.isDigit: digits.add c
    else: break
  if digits.len == 0:
    raise newException(ValueError, "no thread id in: " & s)
  parseInt(digits)

proc unopt(n: JsonNode): JsonNode =
  ## Nim's Option[T] may serialize as null, the value, or {"has":..,"val":..}.
  if n.isNil or n.kind == JNull: return nil
  if n.kind == JObject and n.hasKey("has"):
    return (if n["has"].getBool: n{"val"} else: nil)
  n

proc fmtTs(ts: int64): string =
  fromUnix(ts).utc.format("yyyy-MM-dd HH:mm 'UTC'")

proc fetchThread*(get: Getter, base: string, id: int):
    Future[(JsonNode, seq[JsonNode])] {.async.} =
  let data = parseJson(await get(base & "/posts.json?id=" & $id))
  var posts = initTable[int, JsonNode]()
  for p in data["posts"]: posts[p["id"].getInt] = p
  var missing: seq[int]
  for p in data["posts"]:
    for m in p{"moreBefore"}.getElems:
      if m.getInt notin posts: missing.add m.getInt
  var k = 0
  while k < missing.len:
    let chunk = missing[k ..< min(k + 50, missing.len)]
    let res = parseJson(await get(base & "/specific_posts.json?ids=" &
                                  encodeUrl($(%chunk))))
    for p in res: posts[p["id"].getInt] = p
    k += 50
  var ids = toSeq(posts.keys)
  ids.sort
  result = (data["thread"], ids.mapIt(posts[it]))

proc fetchRaw*(get: Getter, base: string, ids: seq[int]):
    Future[Table[int, string]] {.async.} =
  ## Raw post sources, 8 requests at a time.
  var i = 0
  while i < ids.len:
    let batch = ids[i ..< min(i + 8, ids.len)]
    var futs: seq[Future[string]]
    for id in batch: futs.add get(base & "/post.rst?id=" & $id)
    let bodies = await all(futs)
    for j, id in batch: result[id] = bodies[j]
    i += 8

proc toMarkdown*(base: string, thread: JsonNode, posts: seq[JsonNode],
                 raw: Table[int, string]): string =
  let tid = thread["id"].getInt
  var o: seq[string]
  o.add "# " & thread["topic"].getStr
  o.add ""
  o.add "Source: $1/t/$2 · category: $3 · $4 posts" % [base, $tid,
        thread{"category", "name"}.getStr("?"), $posts.len]
  o.add ""
  for n, p in posts:
    let id = p["id"].getInt
    var head = "## #$1 — $2 · $3" % [$(n + 1), p["author"]["name"].getStr,
                                    fmtTs(p["info"]["creation"].getBiggestInt)]
    let edits = p{"history"}.getElems.len
    if edits > 0: head.add " (edited $1×)" % $edits
    o.add head
    o.add "<!-- post $1: $2/t/$3#$1 -->" % [$id, base, $tid]
    o.add ""
    let rt = unopt(p{"replyingTo"})
    if rt != nil:
      let who = unopt(rt{"author"})
      o.add "> ↪ replying to $1 (post $2)" % [
        (if who != nil: who["name"].getStr else: "?"), $rt{"postId"}.getInt]
      o.add ""
    o.add (if id in raw: raw[id] else: p["info"]["content"].getStr).strip
    o.add ""
    let likes = p{"likes"}.getElems.mapIt(it["name"].getStr)
    if likes.len > 0:
      o.add "*❤ $1: $2*" % [$likes.len, likes.join(", ")]
      o.add ""
  o.join("\n")

proc threadToMarkdown*(get: Getter, base: string, id: int,
                       html = false): Future[string] {.async.} =
  ## `html = true` uses the server-rendered HTML bodies (fewer requests).
  let (thread, posts) = await fetchThread(get, base, id)
  var raw: Table[int, string]
  if not html:
    raw = await fetchRaw(get, base, posts.mapIt(it["id"].getInt))
  result = toMarkdown(base, thread, posts, raw)

# --- tomd converter interface -------------------------------------------

proc canonical*(u: Uri): string =
  ## Cache key / canonical form; raises ValueError for non-thread URLs.
  if not u.path.startsWith("/t/"):
    raise newException(ValueError,
      "expected a thread URL like https://" & Host & "/t/12345")
  DefaultBase & "/t/" & $parseThreadId(u.path)

proc render*(canon: string): Future[string] {.gcsafe.} =
  ## `FORUM_BASE` env var overrides where data is fetched from (for tests).
  threadToMarkdown(httpGet, getEnv("FORUM_BASE", DefaultBase), parseThreadId(canon))

when isMainModule:
  import std/parseopt
  var input, output = ""
  var base = DefaultBase
  var html = false
  for kind, key, val in getopt():
    case kind
    of cmdArgument: input = key
    of cmdLongOption, cmdShortOption:
      case key
      of "o", "output": output = val
      of "base": base = val.strip(chars = {'/'}, leading = false)
      of "html": html = true
      of "h", "help":
        echo "usage: nimforum2md <thread-url-or-id> [-o:file.md] [--html] [--base:url]"
        quit 0
      else: quit "unknown option: " & key
    of cmdEnd: discard
  if input == "": quit "usage: nimforum2md <thread-url-or-id> [-o:file.md] [--html]"
  let md = waitFor threadToMarkdown(httpGet, base, parseThreadId(input), html)
  if output == "": stdout.write md
  else: writeFile(output, md)
