#!/usr/bin/env python3
"""Generate small, synthetic document-workflow fixtures (reportlab/Pillow/pypdf)."""
import json
from pathlib import Path
import sys

from PIL import Image, ImageDraw, ImageFont
from reportlab.pdfgen import canvas
from pypdf import PdfReader, PdfWriter


def main():
    root = Path(sys.argv[1])
    root.mkdir(parents=True, exist_ok=True)
    english_font = ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf', 38)
    japanese_font = ImageFont.truetype(str(next(Path('/System/Library/Fonts').glob('*W3.ttc'))), 36)
    native_pages = [
        ['E2E Native Reading', 'Project token: ORCHID731.',
         'Ada Lovelace discussed the book Analytical Engine Notes.',
         'Location: London. Date: 1843-08-01.',
         'Literal characters: # heading, **bold**, <img src=x>.'],
        ['E2E Native Page Two', 'The second-page token is CEDAR953.',
         'The meeting took place in Kyoto on 2026-10-24.'],
        ['E2E Native Last Page', 'The final-page token is WILLOW842.',
         'This is physical page three.'],
    ]
    pdf = canvas.Canvas(str(root / 'native.pdf'), pagesize=(600, 800))
    for number, lines in enumerate(native_pages, 1):
        for index, line in enumerate(lines):
            pdf.setFont('Helvetica', 15 if index else 22)
            pdf.drawString(42, 730 - index * 42, line)
        pdf.setFont('Helvetica', 12)
        pdf.drawString(300, 35, str(number))
        pdf.showPage()
    pdf.save()

    scanned_pages = [
        ['E2E SCANNED READING', 'Project token: MAPLE624.',
         'Ada Lovelace wrote Analytical Engine Notes.',
         'Location: London. Date: 1843-08-01.'],
        ['E2E SCANNED PAGE TWO', 'Page token: BIRCH275.',
         'The library is in Kyoto.', 'The book is The Orchid Atlas.'],
    ]
    for number, lines in enumerate(scanned_pages, 1):
        image = Image.new('RGB', (1200, 1600), 'white')
        draw = ImageDraw.Draw(image)
        for index, line in enumerate(lines):
            draw.text((75, 170 + index * 115), line, font=english_font, fill='black')
        image.save(root / f'scanned-page-{number}.png')
    pdf = canvas.Canvas(str(root / 'scanned.pdf'), pagesize=(600, 800))
    for number in (1, 2):
        pdf.drawImage(str(root / f'scanned-page-{number}.png'), 0, 0, width=600, height=800)
        pdf.showPage()
    pdf.save()

    vertical_columns = ['縦書き読書テスト', '大前研一の著書', '世界が見える／日本が見える',
                        '東京で一九八六年に読んだ', '記録番号は桜七三一', 'これは検証用の文章です']
    image = Image.new('RGB', (1000, 1400), 'white')
    draw = ImageDraw.Draw(image)
    for column, text in enumerate(vertical_columns):
        for row, character in enumerate(text):
            draw.text((840 - column * 125, 150 + row * 48), character, font=japanese_font, fill='black')
    draw.text((70, 1260), '1986年', font=japanese_font, fill='black')
    image.save(root / 'vertical-ja.png')
    pdf = canvas.Canvas(str(root / 'vertical-ja.pdf'), pagesize=(500, 700))
    pdf.drawImage(str(root / 'vertical-ja.png'), 0, 0, width=500, height=700)
    pdf.showPage()
    pdf.save()
    mixed = PdfWriter()
    mixed.add_page(PdfReader(root / 'native.pdf').pages[0])
    mixed.add_page(PdfReader(root / 'scanned.pdf').pages[0])
    mixed.add_blank_page(600, 800)
    mixed.write(root / 'mixed.pdf')
    (root / 'corrupt.pdf').write_bytes(b'%PDF-1.7\ninvalid document\n')
    (root / 'oversized.pdf').write_bytes(b'%PDF-1.7\n' + b'x' * 1_048_576)
    (root / 'writing.md').write_text('# E2E writing\nORCHID731\n<><>\nSecond\n<><>\nThird\n<><>\nFourth\n---\nStill fourth\n\\<><>\n```\n<><>\n```\n', encoding='utf-8')
    (root / 'oracle.json').write_text(json.dumps({
        'native': native_pages, 'scanned': scanned_pages, 'verticalJapanese': vertical_columns,
        'verticalEntities': ['大前研一', '世界が見える／日本が見える', '東京', '1986'],
    }, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    for name in ('native.pdf', 'scanned.pdf', 'vertical-ja.pdf', 'mixed.pdf'):
        file = root / name
        print(f'{name}: {len(PdfReader(file).pages)} pages, {file.stat().st_size} bytes')


if __name__ == '__main__':
    main()
