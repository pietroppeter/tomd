## Render a Google Scholar profile as Markdown.
##
## Scholar has no API, so this parses the profile page
## (`/citations?user=<id>`): one request, the 100 most cited articles.
## Scholar's robots.txt allows `/citations?user=` but disallows paging with
## `cstart=`, so we don't page. It often answers datacenter
## IPs with a CAPTCHA page or a 429 instead: that raises `BlockedError`, so the
## server says so rather than returning an empty profile.
##
## tomd converter for scholar.google.com (`canonical` + `render`), also a CLI:
##   nim c -d:ssl -r src/tomd/scholar.nim 'https://scholar.google.com/citations?user=XXXXXXXXXXXX' [-o:profile.md]

import std/[asyncdispatch, httpclient, strutils, uri, xmltree, json, os]
{.warning[Deprecated]: off.}
import std/htmlparser   # deprecated in favour of pkg/htmlparser, still in 2.2
{.warning[Deprecated]: on.}
from nimforum import UserAgent, NotFoundError

const
  Host* = "scholar.google.com"
  DefaultBase* = "https://" & Host
  PageSize = 100    # the most Scholar shows on one page

type
  BlockedError* = object of IOError  ## Scholar refused us (CAPTCHA, 429)

proc fetch(url: string): Future[string] {.async, gcsafe.} =
  let c = newAsyncHttpClient(userAgent = UserAgent,
                             headers = newHttpHeaders({"Accept-Language": "en"}))
  try:
    let r = await c.get(url)
    if r.code == Http404:
      raise newException(NotFoundError, url & " -> " & $r.code)
    if r.code in [Http403, Http429]:
      raise newException(BlockedError,
        "Google Scholar refused the request (" & $r.code & "); it often blocks server IPs")
    if not r.code.is2xx:
      raise newException(IOError, url & " -> " & $r.code)
    result = await r.body
  finally:
    c.close()

proc parseUserId*(s: string): string =
  ## Accepts a profile URL (any query order) or a bare id.
  let t = s.strip
  if "user=" notin t:
    result = t
  else:
    for k, v in decodeQuery(parseUri(t).query):
      if k == "user": result = v
  if result.len == 0 or not result.allCharsInSet(IdentChars + {'-'}):
    raise newException(ValueError, "no Scholar user id in: " & s)

# --- HTML helpers ---------------------------------------------------------

proc cls(n: XmlNode): seq[string] =
  if n.kind == xnElement and n.attrs != nil: n.attr("class").splitWhitespace
  else: @[]

proc collect(n: XmlNode, pred: proc (n: XmlNode): bool {.gcsafe.}, acc: var seq[XmlNode]) =
  if n.kind != xnElement: return
  if pred(n): acc.add n
  for c in n: collect(c, pred, acc)

proc byClass(n: XmlNode, c: string): seq[XmlNode] =
  collect(n, proc (x: XmlNode): bool = c in x.cls, result)

proc byId(n: XmlNode, id: string): XmlNode =
  var acc: seq[XmlNode]
  collect(n, proc (x: XmlNode): bool = x.attrs != nil and x.attr("id") == id, acc)
  if acc.len > 0: acc[0] else: nil

proc txt(n: XmlNode): string =
  if n.isNil: "" else: n.innerText.splitWhitespace.join(" ")

proc absUrl(href: string): string =
  if href.startsWith("/"): DefaultBase & href else: href

# --- parsing --------------------------------------------------------------

type
  Article* = object
    title*, url*, authors*, venue*, year*, citedBy*: string
  Profile* = object
    name*, affiliation*, email*, homepage*: string
    interests*: seq[string]
    stats*: seq[(string, string, string)]   ## (label, all, since)
    sinceLabel*: string                      ## e.g. "Since 2021"
    articles*: seq[Article]

proc isProfilePage(doc: XmlNode): bool = doc.byId("gsc_prf_in") != nil

proc parseArticles*(doc: XmlNode): seq[Article] =
  for tr in doc.byClass("gsc_a_tr"):
    var a: Article
    let t = tr.byClass("gsc_a_at")
    if t.len == 0: continue           # "There are no articles" placeholder row
    a.title = t[0].txt
    a.url = absUrl(t[0].attr("href"))
    let gray = tr.byClass("gs_gray")
    if gray.len > 0: a.authors = gray[0].txt
    if gray.len > 1:
      # the venue div ends with a hidden ", <year>" span: drop it
      a.venue = gray[1].txt
      for s in gray[1].byClass("gs_oph"): a.venue.removeSuffix(s.txt)
    let c = tr.byClass("gsc_a_ac")
    if c.len > 0: a.citedBy = c[0].txt
    let y = tr.byClass("gsc_a_h")
    if y.len > 0: a.year = y[0].txt
    result.add a

proc parseProfile*(doc: XmlNode): Profile =
  result.name = doc.byId("gsc_prf_in").txt
  for il in doc.byClass("gsc_prf_il"):
    case il.attr("id")
    of "gsc_prf_ivh":
      result.email = il.txt.split(" - ")[0].strip
      for a in il.byClass("gsc_prf_ila"): result.homepage = a.attr("href")
    of "gsc_prf_int":
      for a in il.byClass("gsc_prf_inta"): result.interests.add a.txt
    else:
      if result.affiliation.len == 0: result.affiliation = il.txt
  let ths = doc.byClass("gsc_rsb_sth")
  if ths.len >= 3: result.sinceLabel = ths[2].txt
  let st = doc.byId("gsc_rsb_st")
  if st != nil:
    for tr in st.findAll("tr"):
      let label = tr.byClass("gsc_rsb_sc1")
      let vals = tr.byClass("gsc_rsb_std")
      if label.len > 0 and vals.len >= 2:
        result.stats.add (label[0].txt, vals[0].txt, vals[1].txt)

proc yamlKey(label: string): string =
  ## "Citations" -> "citations", "h-index" -> "h_index", "Since 2021" -> "since_2021"
  label.toLowerAscii.multiReplace(("-", "_"), (" ", "_"))

proc cell(s: string): string = s.replace("|", "\\|")

proc toMarkdown*(source: string, p: Profile): string =
  ## YAML front matter, then the articles as a table (as listed by Scholar,
  ## most cited first).
  var o: seq[string]
  o.add "---"
  o.add "name: " & escapeJson(p.name)
  o.add "source: " & source
  if p.affiliation.len > 0: o.add "affiliation: " & escapeJson(p.affiliation)
  if p.email.len > 0: o.add "email: " & escapeJson(p.email)
  if p.homepage.len > 0: o.add "homepage: " & escapeJson(p.homepage)
  if p.interests.len > 0:
    var xs: seq[string]
    for i in p.interests: xs.add escapeJson(i)
    o.add "interests: [" & xs.join(", ") & "]"
  let since = p.sinceLabel.yamlKey
  for (label, all, recent) in p.stats:
    o.add "$1: {all: $2$3}" % [label.yamlKey, all,
      (if since.len > 0: ", " & since & ": " & recent else: "")]
  o.add "articles: " & $p.articles.len
  o.add "---"
  o.add ""
  o.add "| # | Title | Authors | Venue | Year | Cited by |"
  o.add "|---|---|---|---|---|---|"
  for i, a in p.articles:
    o.add "| $1 | [$2]($3) | $4 | $5 | $6 | $7 |" % [$(i + 1), a.title.cell,
      a.url, a.authors.cell, a.venue.cell, a.year, a.citedBy]
  o.add ""
  o.join("\n")

proc profileToMarkdown*(base, id: string): Future[string] {.async.} =
  let url = "$1/citations?user=$2&hl=en&pagesize=$3" % [base, encodeUrl(id), $PageSize]
  let doc = parseHtml(await fetch(url))
  if not doc.isProfilePage:
    raise newException(BlockedError,
      "Google Scholar did not return a profile page (likely a CAPTCHA); " &
      "it often blocks server IPs")
  var profile = parseProfile(doc)
  profile.articles = parseArticles(doc)
  result = toMarkdown(DefaultBase & "/citations?user=" & id, profile)

# --- tomd converter interface -------------------------------------------

proc canonical*(u: Uri): string =
  ## Cache key / canonical form; raises ValueError for non-profile URLs.
  if u.path != "/citations" or "user=" notin u.query:
    raise newException(ValueError,
      "expected a profile URL like https://" & Host & "/citations?user=XXXXXXXXXXXX")
  DefaultBase & "/citations?user=" & parseUserId($u)

proc render*(canon: string): Future[string] {.gcsafe.} =
  ## `SCHOLAR_BASE` env var overrides where pages are fetched from (for tests).
  profileToMarkdown(getEnv("SCHOLAR_BASE", DefaultBase), parseUserId(canon))

when isMainModule:
  import std/parseopt
  var input, output = ""
  for kind, key, val in getopt():
    case kind
    of cmdArgument: input = key
    of cmdLongOption, cmdShortOption:
      case key
      of "o", "output": output = val
      else: quit "usage: scholar <profile-url-or-id> [-o:file.md]"
    of cmdEnd: discard
  if input == "": quit "usage: scholar <profile-url-or-id> [-o:file.md]"
  let md = waitFor profileToMarkdown(DefaultBase, parseUserId(input))
  if output == "": stdout.write md
  else: writeFile(output, md)
