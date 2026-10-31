"""Prioritize residual alerts and preserve unusable non-speech text separately."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys

import caption_maintenance as maintenance
import caption_quality as quality
import caption_source_repair as source
import pipeline_core as core


def non_speech_loop(title,text):
    music=bool(re.search(r'\b(?:lofi|music|musique|fireplace|ambient|relaxation)\b',title,re.I))
    silent=bool(re.search(r'no talking|sans parole',title,re.I))
    words=text.split();sentences=[' '.join(s.split()).casefold() for s in re.split(r'(?<=[.!?])\s+',text) if s.strip()]
    counts=Counter(sentences)
    repeated=max(((len(sentence.split())*count,count,sentence) for sentence,count in counts.items()),default=(0,0,''))
    fraction=repeated[0]/max(1,len(words))
    accepted=music and silent and len(words)>=500 and repeated[1]>=20 and fraction>=.90
    return dict(accepted=accepted,word_count=len(words),dominant_sentence_fraction=fraction,
                dominant_sentence_occurrences=repeated[1],dominant_sentence=repeated[2][:500],
                music_title=music,no_speech_title=silent)


def prepare_exclusions(runtime,target):
    plan=json.loads((target/'PLAN.json').read_text(encoding='utf8'));rules=[]
    with core.closing_database(core.connect(runtime.db,True)) as db:
        for row in db.execute("SELECT youtube_id,title,transcript FROM videos WHERE trim(COALESCE(transcript,''))!='' AND (lower(title) LIKE '%no talking%' OR lower(title) LIKE '%sans parole%')"):
            proof=non_speech_loop(row['title'],row['transcript'])
            if proof['accepted']:
                rules.append(dict(youtube_id=row['youtube_id'],title=row['title'],sha256=maintenance.digest(row['transcript']),
                                  reason='Boucle de sous-titres inexploitable sur une vidéo musicale indiquée sans parole',evidence=proof))
    plan['exclusions']=rules;core.atomic_json(target/'PLAN.json',plan);maintenance.report(target,plan)
    print(json.dumps(dict(quality_exclusions=len(rules),texts_unchanged=True)),flush=True)


def classify(q,source_verified=False,excluded=False):
    s=q['review_signals'];alerts=q['suspected_repetitions']
    if excluded:return 'excluded_non_speech_loop'
    if q['technical_markers'] or s['encoding_artifacts']:return 'priority_encoding_or_markup'
    if not alerts:return 'no_remaining_alert'
    if alerts<=s['nonverbal_only_alerts']+s['short_filler_alerts']:return 'annotations_or_short_oral_fillers'
    if source_verified:return 'matches_local_timed_source'
    if (s['repeated_word_fraction']>=.10 and s['long_repetition_alerts']>=2
            or s['longest_repeated_unit']>=10 and s['long_repetition_alerts']>=5):
        return 'priority_long_repetitions'
    return 'preserved_unconfirmed_oral_repetition'


def final_report(runtime,target):
    done=json.loads((target/'DONE.json').read_text(encoding='utf8'))
    plan=json.loads((target/'PLAN.json').read_text(encoding='utf8'))
    audit=json.loads((Path(done['audit'])/'RESULT.json').read_text(encoding='utf8'))
    flagged={x['youtube_id']:x for x in audit['flagged']};notes={x['youtube_id']:x for x in plan['notes']}
    counts=Counter();records=[]
    with core.closing_database(core.connect(runtime.db,True)) as db:
        excluded=core.quality_exclusions(runtime,db)
        for row in db.execute("SELECT v.youtube_id,v.title,v.transcript,c.prefix AS channel FROM videos v JOIN channels c ON c.id=v.channel_id WHERE trim(COALESCE(v.transcript,''))!='' ORDER BY v.id"):
            ident=row['youtube_id'];text=row['transcript']
            if ident not in flagged and ident not in excluded and not source.CORRUPTION.search(text):continue
            q=flagged[ident]['quality'] if ident in flagged else quality.inspect_text(text)
            note=notes.get(ident,{})
            verified=(note.get('reason') in {'same_text','same_after_legacy_single_word_collapse'}
                      and note.get('text_sha')==maintenance.digest(text))
            category=classify(q,verified,ident in excluded);counts[category]+=1
            records.append(dict(youtube_id=ident,title=row['title'],channel=row['channel'],category=category,
                                quality=q,source_result=note.get('reason'),text_sha256=maintenance.digest(text),
                                opening=text[:700] if category.startswith('priority') else None))
    priority=[x for x in records if x['category'].startswith('priority')]
    priority.sort(key=lambda x:(-x['quality']['review_signals']['encoding_artifacts'],
                                -x['quality']['review_signals']['repeated_word_fraction']))
    result=dict(counts=dict(counts),priority_count=len(priority),classified_texts=len(records),
                baseline_raw_repetition_texts=12556,final_raw_status_counts=audit['status_counts'],
                records=records,network_calls=0,generated_at=core.now())
    core.atomic_json(target/'FINAL_TRIAGE.json',result)
    text='# Relecture résiduelle après traitement automatique\n\n'
    text+='Les alertes brutes ne sont pas une liste d’erreurs certaines. Les annotations sonores, les hésitations courtes et les textes concordants avec leur source sont distingués des cas prioritaires. Les répétitions conservées ne sont pas toutes certifiées comme prononcées ; elles restent présentes faute de preuve suffisante pour les retirer.\n\n'
    labels=dict(excluded_non_speech_loop='Boucle sans parole exploitable écartée des packs, original conservé',
                priority_encoding_or_markup='Priorité : encodage ou marqueurs non résolus',priority_long_repetitions='Priorité : répétitions longues encore suspectes',
                annotations_or_short_oral_fillers='Annotations sonores ou hésitations courtes conservées',matches_local_timed_source='Concordance avec une source horodatée locale',
                preserved_unconfirmed_oral_repetition='Reprises conservées sans indice suffisant pour une correction',no_remaining_alert='Aucune alerte restante')
    for key,count in counts.items():text+=f'- {labels[key]} : {count}\n'
    text+=f'\n**{len(priority)} cas prioritaires**, au lieu de demander une relecture de toute la liste brute. Ce classement ne garantit pas que tous les cas de faible priorité sont exempts d’erreur.\n'
    text+='\n## Cas prioritaires\n'
    for item in priority[:30]:
        q=item['quality'];s=q['review_signals']
        text+=f"\n### {item['channel']} — {item['title']}\n\nIdentifiant : `{item['youtube_id']}`. {labels[item['category']]}. Résultat de recherche locale : `{item['source_result'] or 'voir les preuves du plan'}`.\n\nArtefacts d’encodage : {s['encoding_artifacts']}. Alertes de répétition : {q['suspected_repetitions']}, dont {s['long_repetition_alerts']} longues.\n\n```text\n{item['opening']}\n```\n"
    text+='\nLa liste complète et ses critères figurent dans FINAL_TRIAGE.json. Aucune nouvelle récupération YouTube ou transcription audio n’a été lancée.\n'
    (target/'REVIEW.md').write_text(text,encoding='utf8')
    summary=target/'SUMMARY.md'
    with summary.open('a',encoding='utf8') as handle:
        handle.write(f'\n## Relecture ciblée\n\n{len(priority)} cas prioritaires identifiés après classement automatique. [Liste ciblée et limites du classement](REVIEW.md). Les autres alertes restent conservées sans vous imposer leur relecture globale.\n')
    print(json.dumps(dict(counts=counts,priority_count=len(priority))),flush=True)


if __name__=='__main__':
    sys.stdout.reconfigure(encoding='utf8',errors='replace');p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,default=Path(__file__).resolve().parent.parent);p.add_argument('--plan',type=Path,required=True)
    p.add_argument('--prepare-exclusions',action='store_true');args=p.parse_args();runtime=core.Runtime(args.root);target=args.plan.resolve()
    if not target.is_relative_to((runtime.database_dir/'pilot_reports').resolve()):raise ValueError('Private report required')
    prepare_exclusions(runtime,target) if args.prepare_exclusions else final_report(runtime,target)
