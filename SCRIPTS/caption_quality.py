"""Offline diagnostics and review copies. Never updates production transcripts."""
import argparse
from bisect import bisect_left, bisect_right
from collections import Counter
import difflib
import gzip
import hashlib
import json
from pathlib import Path
import re
import sys
import time

import pipeline_core as core
import caption_reconstruction


MARKERS = {
    'downloader_metadata': re.compile(r'\A\s*\{\s*"id"\s*:\s*"[A-Za-z0-9_-]{11}"(?=[\s\S]{0,8192}"formats"\s*:)'),
    'inline_timestamp': re.compile(r'(?:<|&lt;|&amp;lt;|&#60;)(?:\d+:)?\d{2}:\d{2}[.,]\d{3}(?:>|&gt;|&amp;gt;|&#62;)'),
    'cue_timing': re.compile(r'\b(?:\d{2,}:)?\d{2}:\d{2}[.,]\d{3}\s*-->'),
    'orphan_timecode': re.compile(r'(?<!\w)\d{2,}:\d{2}:\d{2}[.,]\d{3}(?!\d)'),
    'cue_tag': re.compile(r'(?:<|&lt;|&amp;lt;)/?(?:c(?:\.[\w.-]+)*|v|lang|ruby|rt)(?:\s[^<>]*?)?(?:>|&gt;|&amp;gt;)',re.I),
    'cue_settings': re.compile(r'\b(?:align|position|line|size|vertical):(?:start|middle|end|center|left|right|rl|lr|\d+(?:\.\d+)?%?)\b',re.I),
    'vtt_header': re.compile(r'\bWEBVTT\b|(?:^|\n)(?:Kind:\s*captions|Language:\s*[a-z]{2})',re.I),
}
TOKEN = re.compile(r"\b[\w’'-]+\b")
SOUND_ANNOTATION = re.compile(r'\[(?:music|musique|applause|applaudissements|laughter|rires|laughs|silence|inaudible)\]',re.I)
ENCODING_ARTIFACT = re.compile(r'\ufffd|Ôò|Ôö|û[▓╣┬│]|[┬├][\x80-\uFFFF]')
FILLERS = set("um uh uhm er ah hmm mm the and so that no yes i you know mean think like well je le la les et donc oui non un euh alors tu sais quoi que des de c’est c'est".split())


def context(text, start, end, radius=100):
    return text[max(0,start-radius):min(len(text),end+radius)]


def inspect_text(text):
    counts={};examples=[]
    for name,pattern in MARKERS.items():
        matches=list(pattern.finditer(text))
        if matches:
            counts[name]=len(matches)
            examples.extend(dict(kind=name,excerpt=context(text,m.start(),m.end())) for m in matches[:2])
    # Bounded token comparisons avoid pathological regex backtracking on long
    # transcripts, and do not mistake repeated VTT markup for spoken words.
    visible=core.strip_caption_markup(text)
    tokens=list(TOKEN.finditer(visible));words=[t[0].casefold() for t in tokens]
    annotation_starts={t.start() for event in SOUND_ANNOTATION.finditer(visible)
                       for t in TOKEN.finditer(visible,event.start(),event.end())}
    positions={}
    for n,word in enumerate(words):positions.setdefault(word,[]).append(n)
    repetition_count=0;example_counts=Counter();i=0
    covered_words=0;max_unit=0;long_alerts=0;nonverbal_alerts=0;filler_alerts=0
    while i<len(words):
        width=0;kind='repeated_phrase'
        occurrences=positions[words[i]]
        stops=occurrences[bisect_left(occurrences,i+3):bisect_right(occurrences,i+min(12,(len(words)-i)//2))]
        for following in reversed(stops):
            size=following-i
            if words[i:i+size]==words[i+size:i+2*size]:width=2*size;break
        if not width and i+6<=len(words) and words[i:i+2]==words[i+2:i+4]==words[i+4:i+6]:
            width=6;kind='repeated_pair'
        if not width and i+4<=len(words) and len(words[i])>=2 and len(set(words[i:i+4]))==1:
            width=4;kind='repeated_word'
        if width:
            repetition_count+=1
            unit=width//2 if kind=='repeated_phrase' else 2 if kind=='repeated_pair' else 1
            covered_words+=width;max_unit=max(max_unit,unit);long_alerts+=unit>=6
            nonverbal_alerts+=all(t.start() in annotation_starts for t in tokens[i:i+width])
            unit_words=words[i:i+unit]
            short_period=(unit<=2 or len(set(unit_words))==1
                          or unit%2==0 and unit_words==unit_words[:2]*(unit//2))
            filler_alerts+=short_period and all(w in FILLERS for w in words[i:i+width])
            if example_counts[kind]<2:
                examples.append(dict(kind=kind,excerpt=context(visible,tokens[i].start(),tokens[i+width-1].end())))
                example_counts[kind]+=1
            i+=width
        else:i+=1
    status='technical_issue' if counts else 'repetition_review' if repetition_count else 'no_heuristic_alert'
    return dict(status=status,technical_markers=counts,suspected_repetitions=repetition_count,examples=examples,
                review_signals=dict(word_count=len(words),repeated_word_fraction=covered_words/max(1,len(words)),
                                    longest_repeated_unit=max_unit,long_repetition_alerts=long_alerts,
                                    nonverbal_only_alerts=nonverbal_alerts,short_filler_alerts=filler_alerts,
                                    encoding_artifacts=len(ENCODING_ARTIFACT.findall(text))))


def review_source(index,ident,languages):
    for lang in languages:
        for path in index.get((ident,lang),[]):
            try:
                payload=path.read_bytes()
                original=gzip.decompress(payload) if path.suffix=='.gz' else payload
                raw=original.decode('utf-8-sig')
                candidate=core.clean_captions(raw)
                if candidate:
                    return dict(language=lang,path=str(path),original=original,candidate=candidate,
                                extension='srt' if '.srt' in path.suffixes else 'vtt')
            except (OSError,UnicodeError,EOFError):
                continue
    return None


def compare_snippets(before,after):
    words_before=before.split();words_after=after.split();changes=[]
    matcher=difflib.SequenceMatcher(None,words_before,words_after,autojunk=True)
    for tag,i,j,a,b in matcher.get_opcodes():
        if tag=='equal':continue
        changes.append(dict(operation=tag,before=' '.join(words_before[max(0,i-8):min(len(words_before),j+8)])[:800],
                            after=' '.join(words_after[max(0,a-8):min(len(words_after),b+8)])[:800]))
        if len(changes)>=4:break
    return changes


def audit_quality(runtime,channel=None,sample_limit=6,progress=None):
    if not 0<=sample_limit<=20:raise ValueError('Choisir entre 0 et 20 exemples retraités')
    target=runtime.database_dir/'pilot_reports'/('quality-'+str(time.time_ns()))
    target.mkdir(parents=True)
    counts=Counter();marker_counts=Counter();flagged=[];total=0;transcript_hashes={}
    query='''SELECT v.youtube_id,v.title,v.transcript,v.status,c.prefix AS channel,c.lang_config
    FROM videos v JOIN channels c ON c.id=v.channel_id WHERE trim(COALESCE(v.transcript,''))!='' '''
    with core.closing_database(core.connect(runtime.db,True)) as db:
        rows=db.execute(query+(' AND c.prefix=?' if channel else '')+' ORDER BY v.id',(channel,) if channel else ())
        for row in rows:
            total+=1;quality=inspect_text(row['transcript'])
            transcript_hashes[row['youtube_id']]=hashlib.sha256(row['transcript'].encode('utf8')).hexdigest()
            counts[quality['status']]+=1
            for name in quality['technical_markers']:marker_counts[name]+=1
            if quality['status']!='no_heuristic_alert':
                flagged.append(dict(youtube_id=row['youtube_id'],title=row['title'],channel=row['channel'],language=row['lang_config'],quality=quality))
            if total%500==0:
                print(f'Qualité : {total} textes analysés, aucun accès réseau',flush=True)
                if progress:progress(total)
    previews=[]
    if sample_limit and flagged:
        inventory=core.caption_inventory(runtime)
        priority=sorted(flagged,key=lambda x:(x['quality']['status']!='technical_issue',-sum(x['quality']['technical_markers'].values())))
        with core.closing_database(core.connect(runtime.db,True)) as db:
            for item in priority:
                if len(previews)>=sample_limit:break
                ident=item['youtube_id'];lang=item['language'] or 'fr'
                languages=['en-orig','en','fr-orig','fr','und'] if lang=='en' else ['fr-orig','fr','en-orig','en','und']
                source=review_source(inventory,ident,languages)
                before=db.execute('SELECT transcript FROM videos WHERE youtube_id=?',(ident,)).fetchone()[0]
                mode='raw_captions' if source else 'text_markup_only'
                reconstruction=None
                if not source:
                    reconstruction=caption_reconstruction.reconstruct(before)
                    if reconstruction['mode']=='rendered_triplets':mode='rendered_triplet_reconstruction'
                    source=dict(language='und',path='production transcript; raw VTT/SRT not found',
                                original=before.encode('utf-8'),candidate=reconstruction['text'],extension='txt')
                sample_dir=target/ident;sample_dir.mkdir()
                (sample_dir/'before.txt').write_text(before,encoding='utf-8')
                (sample_dir/'after.txt').write_text(source['candidate'],encoding='utf-8')
                archive=sample_dir/f"original.{source['language']}.{source['extension']}.gz"
                archive.write_bytes(gzip.compress(source['original'],mtime=0))
                if gzip.decompress(archive.read_bytes())!=source['original']:raise RuntimeError('Archive source invalide')
                after_quality=inspect_text(source['candidate'])
                if reconstruction and reconstruction['mode']=='rendered_triplets':
                    snippets=[dict(operation=e['kind'],before=e['before'],after=e['after']) for e in reconstruction['edits']]
                else:snippets=compare_snippets(before,source['candidate'])
                preview=dict(youtube_id=ident,title=item['title'],channel=item['channel'],source_path=source['path'],
                             language=source['language'],source_sha256=hashlib.sha256(source['original']).hexdigest(),
                             cleaner_version=core.CAPTION_VERSION,reprocessing_mode=mode,before_quality=item['quality'],after_quality=after_quality,
                             before_characters=len(before),after_characters=len(source['candidate']),
                             reconstruction={k:v for k,v in reconstruction.items() if k!='text'} if reconstruction else None,
                             snippet_scope='same_source_block' if mode=='rendered_triplet_reconstruction' else 'sequence_alignment_indicative',
                             snippets=snippets,opening_after=source['candidate'][:1800],production_modified=False)
                core.atomic_json(sample_dir/'comparison.json',preview)
                previews.append(preview)
    report=dict(generated_at=core.now(),texts_scanned=total,status_counts=dict(counts),marker_text_counts=dict(marker_counts),
                flagged=flagged,previews=previews,network_requests=0,production_modified=False,
                transcript_hashes=transcript_hashes,
                note='Les répétitions sont des alertes à relire, pas une preuve de défaut. Aucune alerte ne garantit pas une transcription parfaite.')
    core.atomic_json(target/'RESULT.json',report)
    markdown='# Contrôle qualité des transcriptions\n\nLecture seule de la base. Aucun accès à YouTube, aucun audio, aucun texte de production remplacé.\n\n'
    markdown+=f'Textes analysés : **{total}**.\n\n| Résultat | Textes |\n|---|---:|\n'
    labels={'technical_issue':'Marqueurs techniques suspects','repetition_review':'Répétitions à relire','no_heuristic_alert':'Aucune alerte heuristique'}
    for key,count in counts.items():markdown+=f'| {labels[key]} | {count} |\n'
    markdown+='\nLes répétitions peuvent être réellement prononcées. Cet audit reste en lecture seule ; les corrections suivent la politique de déduplication choisie.\n'
    for item in previews:
        ident=item['youtube_id'];markdown+=f"\n## {item['channel']} — {item['title']}\n\nVidéo : https://www.youtube.com/watch?v={ident}\n\n[Texte actuel]({ident}/before.txt) · [Copie retraitée]({ident}/after.txt) · [Comparaison détaillée]({ident}/comparison.json)\n\n"
        mode=('Retraitement depuis une source horodatée locale.' if item['reprocessing_mode']=='raw_captions' else
              'Reconstruction des trois affichages d’un même bloc. Chaque copie retirée est identique au bloc conservé. Les groupes sans horodatage sont signalés séparément et restent à valider.' if item['reprocessing_mode']=='rendered_triplet_reconstruction' else
              'Motif de copies non confirmé : seules les balises sont nettoyées, sans suppression de répétitions.')
        markdown+=f"{mode}\n\nMarqueurs techniques avant/après : {sum(item['before_quality']['technical_markers'].values())} / {sum(item['after_quality']['technical_markers'].values())}. Répétitions suspectes avant/après : {item['before_quality']['suspected_repetitions']} / {item['after_quality']['suspected_repetitions']}.\n"
        if item['reconstruction'] and item['reconstruction']['mode']=='rendered_triplets':
            evidence=item['reconstruction']['evidence']
            markdown+=f"\nGroupes horodatés confirmés : {evidence['anchored_groups']}. Groupes sans horodatage inférés du format : {evidence['inferred_untimed_groups']}. Lignes-copies retirées : {item['reconstruction']['removed_copy_lines']}. Tous les blocs source sont comptabilisés.\n\n### Début du texte reconstruit\n\n{item['opening_after']}\n\n### Comparaison du même bloc source\n"
        else:markdown+='\nLes extraits suivants utilisent un alignement indicatif ; consulter les fichiers entiers en cas de décalage.\n'
        for difference in item['snippets'][:2]:
            markdown+=f"\nAvant :\n\n```text\n{difference['before']}\n```\n\nAprès :\n\n```text\n{difference['after']}\n```\n"
    markdown+='\n## Conservation avant nettoyage\n\nUne source horodatée compressée, son empreinte, la provenance et un texte validé suffisent à refaire le traitement hors ligne. Les anciens TXT et packs sont des dérivés régénérables. Si la source manque ou si la qualité reste douteuse, conserver les fichiers existants. Aucun ancien fichier n’est supprimé par ce contrôle.\n'
    (target/'REPORT.md').write_text(markdown,encoding='utf-8')
    print(json.dumps(dict(texts_scanned=total,status_counts=dict(counts),previews=len(previews),report=str(target/'REPORT.md')),ensure_ascii=False))
    return report,target


def main():
    if hasattr(sys.stdout,'reconfigure'):sys.stdout.reconfigure(encoding='utf-8',errors='replace')
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--channel')
    parser.add_argument('--samples',type=int,default=6)
    args=parser.parse_args()
    audit_quality(core.Runtime(args.root),args.channel,args.samples)


if __name__=='__main__':main()
