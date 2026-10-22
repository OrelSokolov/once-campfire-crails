require "../app/helpers/html_sanitizer"

def t(input, expect)
  got = HtmlSanitizer.sanitize(input)
  puts(got == expect ? "OK   #{input.inspect}" : "FAIL #{input.inspect}\n  got:    #{got.inspect}\n  expect: #{expect.inspect}")
end

# Пасс-тROUGH (паритет): чистый контент редактора не меняется
t(%(<div>Hello <strong>world</strong></div>), %(<div>Hello <strong>world</strong></div>))
t(%(<h1>Title</h1><p>Text <em>em</em> <s>strike</s> <u>under</u> <mark>mark</mark></p>),
  %(<h1>Title</h1><p>Text <em>em</em> <s>strike</s> <u>under</u> <mark>mark</mark></p>))
t(%(<a href="https://example.com/page">link</a>), %(<a href="https://example.com/page">link</a>))
t(%(<pre><code class="ruby">puts 1</code></pre>), %(<pre><code class="ruby">puts 1</code></pre>))
t(%(<table><thead><tr><th>a</th></tr></thead><tbody><tr><td>b</td></tr></tbody></table>),
  %(<table><thead><tr><th>a</th></tr></thead><tbody><tr><td>b</td></tr></tbody></table>))
t(%(<action-text-attachment sgid="abc" content-type="image/png" width="10"></action-text-attachment>),
  %(<action-text-attachment sgid="abc" content-type="image/png" width="10"></action-text-attachment>))
t(%(<figure class="attachment"><figcaption>cap</figcaption></figure>),
  %(<figure class="attachment"><figcaption>cap</figcaption></figure>))
t(%(<blockquote cite="https://x.co">q</blockquote>), %(<blockquote cite="https://x.co">q</blockquote>))
t(%(<br><hr><br/>), %(<br><hr><br/>))
t(%(<img src="https://x.co/i.png" alt="i" width="1" height="2">), %(<img src="https://x.co/i.png" alt="i" width="1" height="2">))

# XSS: скрипты удаляются с содержимым
t(%(a<script>alert(1)</script>b), %(ab))
t(%(a<script src="https://evil"></script>b), %(ab))
t(%(a<SCRIPT>x</SCRIPT>b), %(ab))
t(%(<style>body{}</style>ok), %(ok))
t(%(<iframe src="https://evil"><p>hi</p></iframe>after), %(after))
t(%(<form action="/x"><input name="a"><button>go</button></form>tail), %(tail))
t(%(<math><mi>x</mi></math>ok), %(ok))

# XSS: обработчики и атрибуты
t(%(<img src="x" onerror="alert(1)">), %(<img src="x">))
t(%(<div onclick="alert(1)" class="c">t</div>), %(<div class="c">t</div>))
t(%(<a href="javascript:alert(1)">x</a>), %(<a>x</a>))
t(%(<a href="JaVaScRiPt:alert(1)">x</a>), %(<a>x</a>))
t(%(<a href=" javascript:alert(1)">x</a>), %(<a>x</a>))
t(%(<a href="java&#115;cript:alert(1)">x</a>), %(<a>x</a>))
t(%(<a href="&#106;avascript:alert(1)">x</a>), %(<a>x</a>))
t(%(<a href="&#x6a;avascript:alert(1)">x</a>), %(<a>x</a>))
t(%(<a href="vbscript:x">y</a>), %(<a>y</a>))
t(%(<a href="data:text/html,x">y</a>), %(<a>y</a>))
t(%(<a href="/rel">ok</a>), %(<a href="/rel">ok</a>))
t(%(<a href="mailto:a@b.c">m</a>), %(<a href="mailto:a@b.c">m</a>))
t(%(<a href="#anchor">m</a>), %(<a href="#anchor">m</a>))

# Комментарии и doctype
t(%(a<!-- hidden -->b), %(ab))
t(%(a<!DOCTYPE html>b), %(ab))

# Незакрытый script — хвост срезается
t(%(pre<script>alert(1)), %(pre))

# Вложенные запрещённые
t(%(<div><object><embed src="x"></object></div>ok), %(<div></div>ok))
t(%(<div><section><p>k</p></section></div>), %(<div></div>))

# Разрешённый внутри запрещённого уходит вместе с родителем
t(%(<x><strong>keep?</strong></x>), %())
