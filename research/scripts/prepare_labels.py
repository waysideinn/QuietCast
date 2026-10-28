#!/usr/bin/env python3
"""Build blinded annotation tasks, without rule output or search terms."""
import json
from collect import DATA, write

def main():
    shows = json.loads((DATA/'shows.json').read_text())
    tasks = []
    for s in shows:
        path = DATA/'rss'/(s['id']+'.json')
        r = json.loads(path.read_text()) if path.exists() else {}
        if r.get('status') != 'ok':
            continue
        tasks.append(dict(unit='show', show_id=s['id'], episode_id=None, title=s['title'], description=r['description'], genres=s['genres'], language=r['metadata'].get('language'), episodes=[{'id':e['id'], 'title':e['title'], 'description':e['description']} for e in r['episodes']], source_url=s['feed_url'], label=None, subtype=None, boundary_type=None, rationale=None, annotator=None, label_source=None, labeled_at=None, family_id=None))
        for e in r['episodes']:
            if e['id']:
                tasks.append(dict(unit='episode', show_id=s['id'], episode_id=e['id'], title=e['title'], description=e['description'], show_title=s['title'], source_url=s['feed_url'], label=None, subtype=None, boundary_type=None, rationale=None, annotator=None, label_source=None, labeled_at=None, family_id=None))
    write(DATA/'annotation_tasks.json', tasks)
    labels = DATA/'labels.json'
    if not labels.exists():
        write(labels, [])
    print(f'{len(tasks)} annotation tasks prepared; existing labels preserved')

if __name__ == '__main__':
    main()
