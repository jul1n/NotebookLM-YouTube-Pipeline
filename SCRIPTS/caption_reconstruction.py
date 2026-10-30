"""Recover legacy rendered captions using their local three-copy structure.

This is not a general word/phrase deduplicator. It produces review candidates
and never writes transcripts or contacts a service.
"""
import hashlib
import html
import re

import pipeline_core as core

VERSION = 'rendered-triplets-v1'
STAMP = re.compile(r'<(?:(\d{2,}):)?(\d{2}):(\d{2})[.,](\d{3})>')


def reconstruct(raw):
    parsed=[]
    for number,line in enumerate(raw.splitlines(),1):
        if not line.strip():continue
        decoded=line
        for _ in range(3):decoded=html.unescape(decoded)
        stamps=[int(h or 0)*3600+int(m)*60+int(s)+int(ms)/1000 for h,m,s,ms in STAMP.findall(decoded)]
        text=' '.join(core.strip_caption_markup(line).split())
        if text:
            parsed.append(dict(line=number,raw=line,text=text,times=stamps))

    def triplet(index,anchored):
        if index+2>=len(parsed):return False
        a,b,c=parsed[index:index+3]
        if a['text']!=b['text'] or b['text']!=c['text']:return False
        if b['times'] or c['times']:return False
        if anchored:return bool(a['times'])
        # Infer an untimed cue only inside a strongly confirmed three-copy
        # rendering, with the same blank-line separators as anchored groups.
        return not a['times'] and b['line']-a['line']>=2 and c['line']-b['line']>=2

    timed=sum(bool(p['times']) for p in parsed)
    confirmed=sum(triplet(i,True) for i in range(len(parsed)))
    coverage=confirmed/timed if timed else 0
    # Never apply this format inference to arbitrary prose or complete VTT/SRT.
    eligible=confirmed>=2 and coverage>=0.8 and '-->' not in raw
    if not eligible:
        return dict(text=core.strip_caption_markup(raw),mode='markup_only',version=VERSION,
                    evidence=dict(timed_lines=timed,confirmed_triplets=confirmed,coverage=coverage),
                    removed_copy_lines=0,edits=[],requires_review=True)

    output=[];edits=[];removed=0;anchored=0;inferred=0;i=0;removed_words=0;time_regressions=0;last_time=-1
    while i<len(parsed):
        item=parsed[i]
        if item['times']:
            if item['times'][0]<last_time:time_regressions+=1
            if any(a>b for a,b in zip(item['times'],item['times'][1:])):time_regressions+=1
            last_time=max(last_time,item['times'][-1])
        is_anchored=triplet(i,True)
        is_inferred=not is_anchored and triplet(i,False)
        output.append(item['text'])
        if is_anchored or is_inferred:
            group=parsed[i:i+3]
            # Every removed line must be an exact normalized copy of its kept
            # cue. Words inside that cue, including spoken repetitions, survive.
            assert all(p['text']==item['text'] for p in group)
            removed+=2;removed_words+=2*len(item['text'].split())
            anchored+=int(is_anchored);inferred+=int(is_inferred)
            if len(edits)<8:
                edits.append(dict(kind='timestamp_anchored_triplet' if is_anchored else 'format_inferred_untimed_triplet',
                                  first_line=group[0]['line'],last_line=group[-1]['line'],
                                  before='\n'.join(p['raw'] for p in group),after=item['text'],
                                  time_anchors=item['times'],removed_copies=2))
            i+=3
        else:i+=1
    text=' '.join(output)
    assert len(output)+removed==len(parsed)
    assert len(text.split())==sum(len(p['text'].split()) for p in parsed)-removed_words
    return dict(text=text,mode='rendered_triplets',version=VERSION,requires_review=True,
                source_sha256=hashlib.sha256(raw.encode('utf-8')).hexdigest(),
                result_sha256=hashlib.sha256(text.encode('utf-8')).hexdigest(),
                removed_copy_lines=removed,removed_copy_words=removed_words,
                evidence=dict(timed_lines=timed,confirmed_triplets=confirmed,coverage=coverage,
                              anchored_groups=anchored,inferred_untimed_groups=inferred,
                              timestamp_regressions=time_regressions,
                              source_lines=len(parsed),output_segments=len(output),all_lines_accounted_for=True),
                edits=edits)
