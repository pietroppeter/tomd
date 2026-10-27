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

type
  NotFoundError* = object of IOError  ## upstream answered 404

type Getter* = proc (url: string): Future[string] {.gcsafe.}

proc httpGet*(url: string): Future[string] {.async, gcsafe.} =
  let c = newAsyncHttpClient(userAgent = UserAgent)
  try:
    let r = await c.get(url)
    if r.code == Http404:
      raise newException(NotFoundError, url & " -> " & $r.code)
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

proc isoTs(ts: int64): string =
  fromUnix(ts).utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc toMarkdown*(base: string, thread: JsonNode, posts: seq[JsonNode],
                 raw: Table[int, string]): string =
  ## YAML front matter for the thread (closed by `---`), then each post as a
  ## YAML block opened by `---` and closed by `...` (YAML's end-of-document
  ## marker, also accepted by pandoc), followed by its body. Closing post
  ## blocks with `...` keeps renderers from turning the last YAML line into a
  ## setext heading. Bodies are left as typed (RST, headings, even `---`).
  let tid = thread["id"].getInt
  let url = base & "/t/" & $tid
  var num: Table[int, int]          # post id -> position in thread (1-based)
  var updated = thread{"activity"}.getBiggestInt  # latest post or edit
  for n, p in posts:
    num[p["id"].getInt] = n + 1
    updated = max(updated, p["info"]["creation"].getBiggestInt)
    for h in p{"history"}.getElems: updated = max(updated, h{"creation"}.getBiggestInt)
  var o: seq[string]
  o.add "---"
  o.add "title: " & escapeJson(thread["topic"].getStr)
  o.add "source: " & url
  o.add "category: " & escapeJson(thread{"category", "name"}.getStr("?"))
  o.add "author: " & escapeJson(thread{"author", "name"}.getStr("?"))
  o.add "created_at: " & isoTs(thread{"creation"}.getBiggestInt)
  o.add "updated_at: " & isoTs(updated)
  o.add "posts: " & $posts.len
  o.add "---"
  for n, p in posts:
    let id = p["id"].getInt
    o.add ""
    o.add "---"
    o.add "post: " & $(n + 1)
    o.add "id: " & $id
    o.add "url: $1#$2" % [url, $id]
    o.add "author: " & escapeJson(p["author"]["name"].getStr)
    o.add "created_at: " & isoTs(p["info"]["creation"].getBiggestInt)
    let history = p{"history"}.getElems
    if history.len > 0:
      var last = 0'i64
      for h in history: last = max(last, h{"creation"}.getBiggestInt)
      o.add "updated_at: " & isoTs(last)
      o.add "edits: " & $history.len
    let rt = unopt(p{"replyingTo"})
    if rt != nil:
      let rid = rt{"postId"}.getInt
      o.add "reply_to: " & (if rid in num: $num[rid] else: "null")
      o.add "reply_to_id: " & $rid
      let who = unopt(rt{"author"})
      if who != nil: o.add "reply_to_author: " & escapeJson(who["name"].getStr)
    let likes = p{"likes"}.getElems.mapIt(escapeJson(it["name"].getStr))
    if likes.len > 0: o.add "likes: [" & likes.join(", ") & "]"
    o.add "..."
    o.add ""
    o.add (if id in raw: raw[id] else: p["info"]["content"].getStr).strip
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
