"""Live UI verification against an explicitly supplied, empty local test server.

Run with: uv run --python 3.12 --with playwright==1.61.0 python scripts/test-source-analyses-browser.py
  --endpoint http://127.0.0.1:8788 --artifacts /tmp/kaiba-analysis-evidence
Requires installed Playwright Chromium and a configured real agent provider.
Install the matching browser with the same uv options followed by
`playwright install chromium --only-shell`.
Creates synthetic notes and invokes the provider three times; retains evidence.
"""

import argparse
import json
import time
import urllib.request
from pathlib import Path
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright, expect


def verify_result_layout(page, screenshot):
    """The answer must scroll within the space above the composer on phones."""
    page.set_viewport_size({'width': 390, 'height': 844})
    transcript = page.locator('.reader-conversation .chat-transcript')
    composer = page.locator('.reader-conversation .memo-composer')
    expect(transcript).to_be_visible()
    expect(composer).to_be_visible()
    transcript.evaluate('(element) => { element.scrollTop = element.scrollHeight }')
    text_bounds = transcript.bounding_box()
    composer_bounds = composer.bounding_box()
    assert text_bounds['y'] + text_bounds['height'] <= composer_bounds['y'] + 1, 'Composer overlaps the transcript'
    assert composer_bounds['y'] + composer_bounds['height'] <= 844, 'Composer is below the viewport'
    assert page.evaluate('document.documentElement.scrollWidth <= window.innerWidth'), 'Horizontal overflow'
    page.screenshot(path=str(screenshot), full_page=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--endpoint', required=True)
    parser.add_argument('--artifacts', required=True)
    args = parser.parse_args()
    endpoint = args.endpoint.rstrip('/')
    parsed = urlparse(endpoint)
    assert parsed.scheme == 'http' and parsed.hostname in ('127.0.0.1', 'localhost'), 'Use an isolated loopback server'
    artifacts = Path(args.artifacts)
    artifacts.mkdir(parents=True, exist_ok=True)

    def graphql(query, variables=None):
        request = urllib.request.Request(endpoint + '/graphql', json.dumps({'query': query, 'variables': variables or {}}).encode(), {'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=30) as response:
            result = json.load(response)
        assert not result.get('errors'), result
        return result['data']

    existing = graphql('{ notebooks(limit: 1) { result { accepted } value { notebookId } } }')['notebooks']
    assert existing['result']['accepted'] and not existing['value'], 'Refusing to modify a non-empty store'
    created = graphql('mutation { createNotebook(input: {title: "Analysis verification"}) { result { accepted } notebook { notebookId } } }')['createNotebook']
    assert created['result']['accepted'], created
    book = created['notebook']['notebookId']
    sources = []
    bodies = [
        '# Orchard trial\nThe orchard trial uses code ORCHID731. Mina will measure soil moisture on October 3. The trial compares mulched and bare plots.',
        '# River survey\nThe river survey uses code CEDAR953. Leon will sample water on October 9. The survey compares upstream and downstream sites.',
    ]
    for body in bodies:
        result = graphql('mutation($input: CreateNoteInput!) { createNote(input: $input) { result { accepted } note { noteId } } }', {'input': {'notebookId': book, 'bodyMarkdown': body}})['createNote']
        assert result['result']['accepted'], result
        sources.append(result['note']['noteId'])

    responses = []
    response_handles = []
    requests = []
    errors = []
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True)
        page = browser.new_page(viewport={'width': 1440, 'height': 1000})
        page.on('pageerror', lambda error: errors.append(str(error)))

        def capture(response):
            if response.request.method != 'POST' or not response.url.endswith('/graphql'):
                return
            payload = response.request.post_data_json
            if payload and payload.get('operationName') == 'SendAgentChatMessage':
                requests.append(payload['variables']['input'])
                response_handles.append(response)

        page.on('response', capture)
        page.goto(endpoint + '/#/notebook/' + book)
        panel = page.get_by_role('region', name='Source analyses')
        page.get_by_role('button', name='Analyses', exact=True).click()
        expect(panel.get_by_role('checkbox')).to_have_count(2)
        expect(panel.get_by_role('button', name='Apply to selected notes')).to_be_disabled()
        panel.get_by_role('button', name='Select all', exact=True).click()
        page.screenshot(path=str(artifacts / '01-selected-sources.png'), full_page=True)
        panel.get_by_role('button', name='Apply to selected notes').click()
        expect(panel.get_by_role('button', name='Open result')).to_have_count(2, timeout=30000)
        responses.extend(response.json()['data']['sendAgentChatMessage'] for response in response_handles)
        assert len(responses) == 2 and all(row['result']['accepted'] for row in responses), responses
        assert [row['subjectNoteId'] for row in requests] == sources
        assert all('mode' not in row and 'conversationNotebookId' not in row for row in requests)
        assert len({row['conversationNotebookId'] for row in responses}) == 2
        page.screenshot(path=str(artifacts / '02-submitted.png'), full_page=True)
        panel.get_by_role('button', name='Open result').first.click()
        expect(page).to_have_url(endpoint + '/#/notebook/' + responses[0]['conversationNotebookId'])

        def wait_answer(row, expected, excluded):
            deadline = time.monotonic() + 240
            while time.monotonic() < deadline:
                note = graphql('query($id: String!) { note(noteId: $id) { result { accepted } value { bodyMarkdown metaJSON } } }', {'id': row['turnNoteId']})['note']['value']
                status = json.loads(note['metaJSON'])['kaibaChat']['status']
                if status == 'answered':
                    answer = note['bodyMarkdown'].split('\n## Agent\n', 1)[1]
                    assert expected in answer and excluded not in answer, answer
                    print(json.dumps({'turn': row['turnNoteId'], 'status': status, 'answer': answer}), flush=True)
                    return note
                assert status == 'pending', note
                page.wait_for_timeout(1000)
            raise AssertionError('Timed out waiting for a real agent reply')

        answered = [wait_answer(responses[0], 'ORCHID731', 'CEDAR953'), wait_answer(responses[1], 'CEDAR953', 'ORCHID731')]
        page.reload()
        expect(page.get_by_text('ORCHID731', exact=False).first).to_be_visible(timeout=30000)
        page.screenshot(path=str(artifacts / '03-reloaded-result.png'), full_page=True)
        page.goto(endpoint + '/#/notebook/' + book)
        page.get_by_role('button', name='Analyses', exact=True).click()
        panel.get_by_label('Analysis template', exact=True).select_option('custom')
        panel.get_by_label('Template name', exact=True).fill('Project code')
        panel.get_by_label('Analysis instructions', exact=True).fill('Report the project code and responsible person from this source. Do not use tools.')
        panel.get_by_role('button', name='Save template', exact=True).click()
        expect(panel.get_by_role('button', name='Remove template')).to_be_visible()
        # Wait for the real server-backed debounced preference write.
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            stored = graphql('{ appSetting(key: "web") { result { accepted } valueJSON } }')['appSetting']['valueJSON']
            if stored and any(item['name'] == 'Project code' for item in json.loads(stored).get('analysisTemplates', [])):
                break
            page.wait_for_timeout(200)
        else:
            raise AssertionError('Custom template was not persisted')
        page.reload()
        page.get_by_role('button', name='Analyses', exact=True).click()
        panel.get_by_label('Analysis template', exact=True).select_option(label='Project code')
        panel.get_by_role('checkbox').first.check()
        panel.get_by_role('button', name='Apply to selected notes').click()
        expect(panel.get_by_role('button', name='Open result')).to_have_count(1, timeout=30000)
        responses.append(response_handles[-1].json()['data']['sendAgentChatMessage'])
        assert len(responses) == 3, responses
        assert requests[2]['userMarkdown'].startswith('# Analysis: Project code')
        answered.append(wait_answer(responses[2], 'ORCHID731', 'CEDAR953'))
        for source_id, body in zip(sources, bodies):
            current = graphql('query($id: String!) { note(noteId: $id) { value { bodyMarkdown } } }', {'id': source_id})['note']['value']
            assert current['bodyMarkdown'] == body, 'Analysis modified source text'
        page.screenshot(path=str(artifacts / '04-custom-template.png'), full_page=True)
        page.set_viewport_size({'width': 390, 'height': 844})
        page.screenshot(path=str(artifacts / '05-narrow-layout.png'), full_page=True)
        panel.get_by_role('button', name='Open result').click()
        expect(page.get_by_text('ORCHID731', exact=False).first).to_be_visible(timeout=30000)
        verify_result_layout(page, artifacts / '06-narrow-result.png')
        assert not errors, errors
        (artifacts / 'evidence.json').write_text(json.dumps({'endpoint': endpoint, 'notebookId': book, 'sourceNoteIds': sources, 'requests': requests, 'responses': responses, 'answeredNotes': answered, 'pageErrors': errors}, indent=2))
        browser.close()
    print('PASS: real browser batch, three real replies, source isolation, unchanged sources, custom-template persistence and result reload', flush=True)


if __name__ == '__main__':
    main()
