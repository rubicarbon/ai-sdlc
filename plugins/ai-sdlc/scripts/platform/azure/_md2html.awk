# _md2html.awk — minimal Markdown to HTML for Azure DevOps description fields.
# Handles headings, paragraphs, bullet and numbered lists, task checkboxes,
# fenced code blocks, inline code, bold, links, and escapes HTML. Good enough
# for specs and tickets; the raw Markdown is also kept as the first comment.
function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
function inline(s) {
  s = esc(s)
  # inline code first so its contents are not re-processed
  while (match(s, /`[^`]+`/)) { s = substr(s, 1, RSTART-1) "<code>" substr(s, RSTART+1, RLENGTH-2) "</code>" substr(s, RSTART+RLENGTH) }
  while (match(s, /\*\*[^*]+\*\*/)) { s = substr(s, 1, RSTART-1) "<strong>" substr(s, RSTART+2, RLENGTH-4) "</strong>" substr(s, RSTART+RLENGTH) }
  while (match(s, /\[[^]]+\]\([^)]+\)/)) {
    t = substr(s, RSTART, RLENGTH); txt = t; sub(/\]\(.*$/, "", txt); sub(/^\[/, "", txt)
    url = t; sub(/^.*\]\(/, "", url); sub(/\)$/, "", url)
    s = substr(s, 1, RSTART-1) "<a href=\"" url "\">" txt "</a>" substr(s, RSTART+RLENGTH)
  }
  return s
}
function close_lists() { while (depth > 0) { print (ltype[depth] == "ol" ? "</ol>" : "</ul>"); depth-- } }
function close_para() { if (inpara) { print "</p>"; inpara = 0 } }
BEGIN { depth = 0; inpara = 0; incode = 0 }
{
  line = $0; sub(/\r$/, "", line)
  if (incode) { if (line ~ /^```/) { print "</code></pre>"; incode = 0 } else print esc(line); next }
  if (line ~ /^```/) { close_para(); close_lists(); print "<pre><code>"; incode = 1; next }
  if (line ~ /^[ \t]*$/) { close_para(); close_lists(); next }
  if (match(line, /^#{1,6} /)) { close_para(); close_lists(); n = RLENGTH - 1; print "<h" n ">" inline(substr(line, RLENGTH+1)) "</h" n ">"; next }
  if (match(line, /^[ \t]*([-*+]|[0-9]+\.) /)) {
    close_para()
    indent = 0; while (substr(line, indent+1, 1) == " ") indent++
    lvl = int(indent / 2) + 1
    marker = substr(line, indent+1); sub(/ .*$/, "", marker)
    kind = (marker ~ /^[0-9]/) ? "ol" : "ul"
    text = substr(line, RLENGTH+1)
    box = ""
    if (text ~ /^\[ \] /) { box = "&#9744; "; text = substr(text, 5) } else if (text ~ /^\[[xX]\] /) { box = "&#9745; "; text = substr(text, 5) }
    while (depth > lvl) { print (ltype[depth] == "ol" ? "</ol>" : "</ul>"); depth-- }
    while (depth < lvl) { depth++; ltype[depth] = kind; print (kind == "ol" ? "<ol>" : "<ul>") }
    print "<li>" box inline(text) "</li>"; next
  }
  close_lists()
  if (!inpara) { print "<p>"; inpara = 1 } else print "<br/>"
  print inline(line)
}
END { if (incode) print "</code></pre>"; close_para(); close_lists() }
