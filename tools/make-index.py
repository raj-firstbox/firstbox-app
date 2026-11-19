"""Builds web/index.html (the app page) from web/firstbox.html (the page as it runs inside Claude).

The page itself stays one file, so it can still be published to Claude unchanged.
index.html adds a proper document wrapper and, before the page's own script, the files that let it run
outside Claude: the Supabase library, pdf-lib, the database settings and the cloud connector.

Usage: python3 tools/make-index.py
"""
import os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = open(os.path.join(ROOT, 'web', 'firstbox.html'), encoding='utf-8').read()

cut = src.index('<header')
head, body = src[:cut], src[cut:]
loaders = '\n'.join([
    '<script src="vendor/supabase.js"></script>',
    '<script src="vendor/pdf-lib.min.js"></script>',
    '<script src="config.js"></script>',
    '<script src="firstbox-cloud.js"></script>',
])
i = body.index('<script>')
body = body[:i] + loaders + '\n' + body[i:]

out = ('<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
       '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n'
       '<style>*,*::before,*::after{box-sizing:border-box}html,body{margin:0}[hidden]{display:none!important}</style>\n'
       + head.strip() + '\n</head>\n<body>\n' + body.strip() + '\n</body>\n</html>\n')
open(os.path.join(ROOT, 'web', 'index.html'), 'w', encoding='utf-8').write(out)
print('web/index.html written,', len(out), 'bytes')
