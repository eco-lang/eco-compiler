"""Inline the compiled Elm into index.html: one self-contained page.

    page.py INDEX.html MAIN.js OUT.html
"""
import sys

index, main_js, out = sys.argv[1:4]
html = open(index).read()
tag = '<script src="build/main.js"></script>'
assert tag in html
js = open(main_js).read().replace('</script', '<\\/script')
open(out, 'w').write(html.replace(tag, '<script>\n' + js + '\n</script>'))
