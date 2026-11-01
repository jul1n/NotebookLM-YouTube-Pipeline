"""Offline, reversible repair of legacy metadata and systemic triplicate copies."""
import argparse
from bisect import bisect_right
from collections import Counter
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time

import caption_quality as quality
import pipeline_core as core
from night_runner import integrity

VERSION = 'legacy-metadata-triplicates-v1'
# A paired header at the very beginning is format evidence; an isolated spoken
# word "Language" or a setting mentioned inside a talk is never removed.
HEADER = re.compile(r'\A\s*(?:WEBVTT[^\r\n]*\r?\n\s*)?Kind:\s*captions\s+Language:\s*[a-z]{2,3}(?:-[\w]+)*\b\s*', re.I)
SETTING = re.compile(r'\A(?:align:(?:start|middle|end|center|left|right)|(?:position|line|size):\d+(?:\.\d+)?%(?:,[\w-]+)?|vertical:(?:rl|lr))(?=\s|$)\s*', re.I)


def digest(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def technical_candidate(text):
    match = HEADER.match(text)
    prefix = ''
    if match:
        stop = match.end()
        while setting := SETTING.match(text[stop:]):
            stop += setting.end()
        prefix = text[:stop]
        text = text[stop:]
    # Restrict markup stripping to records which actually have subtitle markup.
    # Do not unescape arbitrary prose or rewrite spelling/punctuation globally.
    anchored=[]
    if quality.MARKERS['inline_timestamp'].search(text) and '-->' not in text:
        lines=text.splitlines(keepends=True)
        visible=[(n,line,' '.join(core.strip_caption_markup(line).split())) for n,line in enumerate(lines) if line.strip()]
        i=0
        while i+2<len(visible):
            a,b,c=visible[i:i+3]
            if (a[2]==b[2]==c[2] and quality.MARKERS['inline_timestamp'].search(a[1])
                    and not quality.MARKERS['inline_timestamp'].search(b[1]+c[1])):
                anchored.append(dict(kept_line=a[0]+1,removed_lines=[b[0]+1,c[0]+1],text=a[2]));i+=3
            else:i+=1
        # For mixed or damaged legacy files remove only independently anchored
        # copies. Never infer untimed groups from this partial structure.
        if len(anchored)>=10:
            removed={n-1 for group in anchored for n in group['removed_lines']}
            text=''.join(line for n,line in enumerate(lines) if n not in removed)
        else:anchored=[]
    if quality.MARKERS['inline_timestamp'].search(text) or quality.MARKERS['cue_tag'].search(text):
        text = core.strip_caption_markup(text)
    return text, dict(removed_header=prefix,independently_anchored_groups=anchored)


def triplicates(text):
    """Infer a whole-document rendering defect, never deduplicate prose globally.

    All copies must match exactly (case and punctuation included). At least 98%
    of tokens must belong to triplicates, with >=100 groups and >=30 long groups.
    Only groups of >=6 tokens are repaired: short spoken repetitions survive.
    Without timestamps this remains a documented format inference, not proof of
    what the speaker said. Every removed span is recoverable from its original.
    """
    tokens = list(re.finditer(r'\S+', text))
    words = [m[0] for m in tokens]
    positions = {}
    for n,word in enumerate(words):positions.setdefault(word,[]).append(n)
    groups = [];i = 0;covered = 0;long_groups = 0;gap = 0;max_gap = 0
    while i < len(words):
        width = 0
        occurrences=positions[words[i]];limit=min(40,(len(words)-i)//3)
        for following in reversed(occurrences[bisect_right(occurrences,i):bisect_right(occurrences,i+limit)]):
            size=following-i
            if words[i]==words[i+2*size] and words[i:i+size] == words[i+size:i+2*size] == words[i+2*size:i+3*size]:
                width = size;break
        if width:
            groups.append((i,width));covered += 3*width
            long_groups += width >= 6
            max_gap = max(max_gap,gap);gap = 0;i += 3*width
        else:
            gap += 1;i += 1
    max_gap = max(max_gap,gap)
    coverage = covered/len(words) if words else 0
    eligible = coverage >= .98 and len(groups) >= 100 and long_groups >= 30 and max_gap <= 40
    evidence = dict(tokens=len(words),groups=len(groups),long_groups=long_groups,
                    coverage=coverage,max_unmatched_tokens=max_gap,eligible=eligible,
                    basis='whole_document_exact_triplicates_without_timestamps')
    if not eligible:
        return text,evidence
    spans = []
    for start,width in groups:
        if width < 6:continue
        # Keep exactly one original occurrence and its whitespace. No word,
        # punctuation or natural repetition inside the retained block is edited.
        spans.append((tokens[start+width].start(),tokens[start+3*width-1].end()))
    output = [];last = 0
    for start,end in spans:
        output.append(text[last:start]);last = end
    output.append(text[last:])
    result = ''.join(output)
    evidence.update(removed_groups=len(spans),removed_tokens=sum(2*w for _,w in groups if w>=6),
                    removed_spans=spans)
    assert len(result.split()) == len(words)-evidence['removed_tokens']
    return result,evidence


def plan(runtime,target,baseline=None):
    target.mkdir(parents=True,exist_ok=False)
    entries=[];counts=Counter();scanned=0
    prior=json.loads(baseline.read_text(encoding='utf8')) if baseline else None
    cached={x['youtube_id']:x['quality'] for x in prior['flagged']} if prior else {}
    with core.closing_database(core.connect(runtime.db,True)) as db:
        for row in db.execute("SELECT v.youtube_id,v.title,v.transcript,c.prefix AS channel FROM videos v JOIN channels c ON c.id=v.channel_id WHERE trim(COALESCE(v.transcript,''))!='' ORDER BY v.id"):
            scanned+=1;text=row['transcript']
            # An earlier read-only audit is only a prioritization cache. Every
            # proposed change is inspected again on its actual current text.
            # A fresh full audit after application catches all remaining cases.
            if scanned%500==0:print(json.dumps(dict(scanned=scanned,categories=counts)),flush=True)
            if prior and row['youtube_id'] not in cached:continue
            before=cached[row['youtube_id']] if prior else quality.inspect_text(text)
            if before['status']=='no_heuristic_alert':continue
            cleaned,metadata=technical_candidate(text)
            candidate,evidence=triplicates(cleaned) if before['suspected_repetitions']>=30 else (cleaned,dict(eligible=False))
            changed=candidate!=text
            if changed and prior:before=quality.inspect_text(text)
            after=quality.inspect_text(candidate) if changed else before
            category=('systemic_triplicates' if evidence['eligible'] else
                      'technical_metadata' if changed else 'unresolved_markup' if before['technical_markers'] else
                      'partial_triplicates_needs_source' if evidence.get('coverage',0)>=.15 and evidence.get('long_groups',0)>=5 else
                      'frequent_repetitions_unconfirmed' if before['suspected_repetitions']>=30 else 'isolated_repetitions_unconfirmed')
            if changed and (not candidate.strip() or after['technical_markers'] or after['suspected_repetitions']>before['suspected_repetitions']):
                category='candidate_rejected';changed=False
            item=dict(youtube_id=row['youtube_id'],title=row['title'],channel=row['channel'],category=category,
                      before_sha=digest(text),after_sha=digest(candidate) if changed else digest(text),
                      apply=changed,before_quality=before,after_quality=after,metadata=metadata,evidence=evidence,
                      source_review_notes=(['very_short_text'] if len(quality.TOKEN.findall(candidate))<20 else []),
                      opening_before=text[:900],opening_after=candidate[:900])
            counts[category]+=1;entries.append(item)
            if changed:
                folder=target/'candidates';folder.mkdir(exist_ok=True)
                (folder/(row['youtube_id']+'.txt.gz')).write_bytes(gzip.compress(candidate.encode('utf8'),mtime=0))
    result=dict(version=VERSION,created_at=core.now(),database=str(runtime.db),texts_scanned=scanned,
                counts=dict(counts),changes=sum(x['apply'] for x in entries),network_calls=0,
                prioritization_audit=str(baseline) if baseline else None,entries=entries)
    core.atomic_json(target/'PLAN.json',result)
    report(target,result)
    print(json.dumps(dict(plan=str(target),changes=result['changes'],counts=counts)),flush=True)


def report(target,result,applied=None):
    text='# Entretien local des transcriptions\n\nAucun accès réseau, aucun audio, aucune suppression de média.\n\n'
    text_changes=sum(not x.get('metadata_only',False) for x in result['entries'])
    text+=f"Textes parcourus : {result['texts_scanned']}. Corrections de texte proposées : {text_changes}. Sources supplémentaires à archiver/lier sans modifier le texte : {result['changes']-text_changes}.\n\n"
    labels=dict(systemic_triplicates='Triples copies systématiques corrigibles',technical_metadata='En-têtes, balises ou copies horodatées corrigibles',
                completed_systemic_triplicates='Reconstruction complète depuis un original à triples copies',short_systemic_triplicates='Formats courts à triples copies variées',verified_local_timed_source='Reconstruction depuis une source horodatée locale concordante',demonstrated_encoding_restoration='Caractères restaurés par correspondances indépendamment démontrées',verified_source_archival_only='Source horodatée archivée et reliée au texte déjà concordant',
                partial_triplicates_needs_source='Triples copies partielles : source à examiner',frequent_repetitions_unconfirmed='Répétitions nombreuses, origine non confirmée',
                isolated_repetitions_unconfirmed='Répétitions moins nombreuses, origine non confirmée',unresolved_markup='Marqueurs techniques non résolus',candidate_rejected='Candidat rejeté par les contrôles')
    labels.update(authorized_adjacent_repetitions='Répétitions adjacentes retirées, y compris tics et emphase autorisés',verified_local_text_source='Texte restauré depuis un export local identifié',verified_source_restoration='Contenu rétabli depuis des sous-titres complets',demonstrated_deep_encoding_restoration='Encodage restauré depuis des correspondances de caractères vérifiées')
    for name,count in result['counts'].items():text+=f'- {labels.get(name,name)} : {count}\n'
    if result.get('spoken_repetitions_removal_authorized'):
        text+='\nSuppression autorisée des copies de mots ou groupes de mots immédiatement adjacents, même réellement prononcés (tics, reprises, emphase). Aucun regroupement de passages éloignés ; les séquences contenant des chiffres restent intactes. Les sources brutes et originaux sont conservés.\n'
    if result.get('source_cleaner'):
        text+='\nLes sources horodatées concordantes sont retraitées en distinguant les nouvelles paroles des lignes maintenues à l’écran. Les anciens triples rendus variés peuvent être reconstruits entièrement : couverture de 98 %, au moins 25 groupes, 20 unités distinctes et 20 groupes longs. Les répétitions à l’intérieur d’une unité conservée restent intactes ; une boucle uniforme ne prouve pas ce format.\n'
        text+='\nLes corrections d’encodage éventuelles reposent sur des modèles de caractères démontrés dans au moins trois vidéos indépendantes, avec au moins dix occurrences et aucune ambiguïté. Elles conservent toutes les lettres et chiffres ASCII dans le même ordre. Aucun mot manquant n’est deviné.\n'
    else:
        text+='\nLes triplicats systématiques sont inférés du format de tout le document (98 % minimum, 100 groupes minimum, 30 groupes longs minimum). Seules les copies de blocs de six mots ou plus sont retirées. Les répétitions courtes, partielles ou isolées restent à relire. Une inférence sans horodatage ne certifie pas la parole originale.\n'
    if applied is not None:text+=f'\nCorrections appliquées et originaux vérifiés : **{applied}**.\n'
    text+='\n## Exemples avant / après\n'
    samples=sorted((x for x in result['entries'] if x['apply']),key=lambda x:x['category'])
    selected=[]
    for category in sorted({x['category'] for x in samples}):
        selected.extend([x for x in samples if x['category']==category][:5])
    for item in selected:
        text+=f"\n### {item['channel']} — {item['title']} ({item['youtube_id']})\n\nAvant :\n\n```text\n{item['opening_before']}\n```\n\nAprès :\n\n```text\n{item['opening_after']}\n```\n"
    text+='\nLe fichier PLAN.json fournit les classifications, preuves et empreintes pour chaque texte signalé. Les originaux modifiés sont conservés compressés et référencés dans pipeline_revisions.\n'
    (target/'REPORT.md').write_text(text,encoding='utf8')


def apply(runtime,target):
    result=json.loads((target/'PLAN.json').read_text(encoding='utf8'))
    if result['version']!=VERSION or Path(result['database'])!=runtime.db:raise ValueError('Plan incompatible')
    job='maintenance-'+target.name
    archive=runtime.root/'WORKING_ZONE'/'_LEGACY_RENDERED_GZ';archive.mkdir(parents=True,exist_ok=True)
    with core.acquisition_lock(runtime):
        core.backup(runtime)
        integrity(runtime)
        with core.closing_database(core.connect(runtime.db)) as db:
            # The existing revision table is mandatory: never silently create a
            # different journal or apply without the established rollback chain.
            db.execute('SELECT id FROM pipeline_revisions LIMIT 1')
            if result.get('exclusions'):
                with db:
                    db.execute('''CREATE TABLE IF NOT EXISTS pipeline_quality_exclusions (
                    youtube_id TEXT,transcript_sha256 TEXT,reason TEXT,evidence TEXT,created_at TEXT,
                    PRIMARY KEY(youtube_id,transcript_sha256))''')
                    for rule in result['exclusions']:
                        active=db.execute('SELECT transcript FROM videos WHERE youtube_id=?',(rule['youtube_id'],)).fetchone()
                        if not active or digest(active[0])!=rule['sha256']:raise RuntimeError('Concurrent edit in quality exclusion')
                        db.execute('INSERT OR IGNORE INTO pipeline_quality_exclusions VALUES(?,?,?,?,?)',
                                   (rule['youtube_id'],rule['sha256'],rule['reason'],json.dumps(rule,ensure_ascii=False),core.now()))
            for item in result['entries']:
                if not item['apply']:continue
                ident=item['youtube_id']
                if not core.VIDEO_ID.fullmatch(ident):raise ValueError('Invalid ID')
                current=db.execute('SELECT transcript FROM videos WHERE youtube_id=?',(ident,)).fetchone()[0]
                if digest(current)==item['after_sha']:
                    if not item.get('metadata_only'):continue
                    present=db.execute('SELECT raw_path,sha256 FROM pipeline_transcripts WHERE youtube_id=?',(ident,)).fetchone()
                    artifact=item.get('timed_source') or item.get('local_text_source')
                    if artifact and present and present['raw_path']==artifact['raw_path'] and present['sha256']==artifact['sha256']:continue
                if digest(current)!=item['before_sha']:raise RuntimeError('Concurrent edit: '+ident)
                candidate=gzip.decompress((target/'candidates'/(ident+'.txt.gz')).read_bytes()).decode('utf8')
                if digest(candidate)!=item['after_sha']:raise RuntimeError('Invalid candidate: '+ident)
                runtime.check_space(128*1024**2)
                path=archive/f"{ident}.{item['before_sha']}.rendered.txt.gz"
                if not path.exists():
                    temp=path.with_suffix('.gz.tmp');temp.write_bytes(gzip.compress(current.encode('utf8'),mtime=0));os.replace(temp,path)
                if hashlib.sha256(gzip.decompress(path.read_bytes())).hexdigest()!=item['before_sha']:raise RuntimeError('Invalid original')
                old=db.execute('SELECT * FROM pipeline_transcripts WHERE youtube_id=?',(ident,)).fetchone()
                with db:
                    db.execute('BEGIN IMMEDIATE')
                    if db.execute('SELECT transcript FROM videos WHERE youtube_id=?',(ident,)).fetchone()[0]!=current:raise RuntimeError('Concurrent edit')
                    if candidate!=current and db.execute('UPDATE videos SET transcript=? WHERE youtube_id=? AND transcript=?',(candidate,ident,current)).rowcount!=1:raise RuntimeError('Concurrent edit')
                    db.execute('INSERT INTO pipeline_revisions(job_id,youtube_id,before_sha,after_sha,original_gzip,old_metadata,proof,changed_at) VALUES(?,?,?,?,?,?,?,?)',
                               (job,ident,item['before_sha'],item['after_sha'],str(path),json.dumps(dict(old)) if old else None,json.dumps(dict(item,maintenance_version=result['version']),ensure_ascii=False),core.now()))
                    artifact=item.get('timed_source') or item.get('local_text_source')
                    if artifact:
                        source=artifact;source_path=Path(source['raw_path'])
                        if hashlib.sha256(gzip.decompress(source_path.read_bytes())).hexdigest()!=source['sha256']:
                            raise RuntimeError('Timed source checksum mismatch')
                        db.execute('INSERT OR REPLACE INTO pipeline_transcripts VALUES(?,?,?,?,?,?,?)',
                                   (ident,source['language'],'verified-local-timed-captions' if item.get('timed_source') else 'verified-local-text-source',str(source_path),source['sha256'],core.CAPTION_VERSION,core.now()))
                    # Preserve the real caption source provenance if present;
                    # this journal describes the derived text transformation.
            revision_count=db.execute('SELECT count(*) FROM pipeline_revisions WHERE job_id=?',(job,)).fetchone()[0]
            applied=db.execute('SELECT count(*) FROM pipeline_revisions WHERE job_id=? AND before_sha!=after_sha',(job,)).fetchone()[0]
            source_links=revision_count-applied
            excluded=len(core.quality_exclusions(runtime,db))
            for row in db.execute('SELECT * FROM pipeline_revisions WHERE job_id=?',(job,)):
                if hashlib.sha256(gzip.decompress(Path(row['original_gzip']).read_bytes())).hexdigest()!=row['before_sha']:raise RuntimeError('Original mismatch')
                active=db.execute('SELECT transcript FROM videos WHERE youtube_id=?',(row['youtube_id'],)).fetchone()[0]
                if digest(active)!=row['after_sha']:raise RuntimeError('Active mismatch')
        checks=integrity(runtime)
        report(target,result,applied)
        core.atomic_json(target/'APPLIED.json',dict(job=job,changed=applied,source_links=source_links,revisions=revision_count,integrity=checks,verified_at=core.now()))
        audit,path=quality.audit_quality(runtime,sample_limit=0)
        core.packs(runtime)
        from dashboard_export import export_dashboard
        export_dashboard(runtime)
        core.backup(runtime)
        core.atomic_json(target/'DONE.json',dict(changed=applied,source_links=source_links,revisions=revision_count,integrity=checks,audit=str(path),counts=audit['status_counts'],finished_at=core.now(),network_calls=0,quality_excluded=excluded))
        summary=f"# Bilan des corrections locales\n\n**{applied} textes corrigés**, originaux compressés et empreintes avant/après revérifiés. SQLite et FTS : contrôles réussis. Packs et dashboard régénérés ; sauvegardes vérifiées avant et après, rétention de trois sauvegardes gérées. Aucun appel réseau, aucun audio ni média supprimé.\n\n"
        if source_links:summary+=f'**{source_links} sources horodatées supplémentaires** archivées et reliées sans modifier leurs textes déjà concordants.\n\n'
        summary+=f"Audit final sur {audit['texts_scanned']} textes :\n\n"
        if excluded:summary+=f'- Textes conservés en base mais écartés des packs et de la recherche pour contenu inexploitable : {excluded}\n'
        for status,label in [('technical_issue','Alertes techniques'),('repetition_review','Textes avec répétitions à examiner'),('no_heuristic_alert','Textes sans alerte de ces règles')]:
            summary+=f"- {label} : {audit['status_counts'].get(status,0)}\n"
        summary+='\nCes nombres décrivent des textes signalés, pas autant d’erreurs confirmées. Des textes précédemment classés techniques peuvent maintenant apparaître dans les répétitions. Les répétitions courtes dans les documents reconstruits restent volontairement présentes.\n\n'
        short=[x for x in result['entries'] if x['apply'] and x['source_review_notes']]
        if short:
            summary+='## Sources très courtes à contrôler\n\nLa disparition des balises ne répare pas un sous-titre incomplet ou peu informatif.\n\n'
            for item in short:summary+=f"- {item['youtube_id']} — {item['channel']} — {item['title']}\n"
        summary+=f"\nOccupation locale gérée : {runtime.usage()/1e9:.2f} Go / {runtime.budget/1e9:g} Go.\n\n[Comparaisons avant/après](REPORT.md). Audit complet : `{path/'REPORT.md'}`. Le plan JSON contient le classement de tous les signalements examinés.\n"
        (target/'SUMMARY.md').write_text(summary,encoding='utf8')
        print((target/'DONE.json').read_text(encoding='utf8'),flush=True)


def main():
    sys.stdout.reconfigure(encoding='utf8',errors='replace')
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--plan',type=Path,required=True)
    parser.add_argument('--apply',action='store_true')
    parser.add_argument('--baseline',type=Path,help='Prior audit used only to prioritize; changed texts are rechecked')
    args=parser.parse_args();runtime=core.Runtime(args.root);target=args.plan.resolve()
    if not target.is_relative_to((runtime.database_dir/'pilot_reports').resolve()):raise ValueError('Plan must be in private reports')
    apply(runtime,target) if args.apply else plan(runtime,target,args.baseline)


if __name__=='__main__':main()
