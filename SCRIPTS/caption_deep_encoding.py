"""Character-only restoration learned from independent matching local texts."""
from collections import Counter
import re
import unicodedata
import caption_source_repair as source
import caption_encoding_repair as encoding

VERSION='independent-character-restoration-v3'


def allowed_artifact(old,new):
    if encoding.allowed_artifact(old,new):return True
    if not old or len(new)>1 or len(old)<2 or re.search(r'\d',old):return False
    if not new and (len(old)<8 or len(source.CORRUPTION.findall(old))<2):return False
    target=not new or (not new.isascii() and unicodedata.name(new,'').startswith('LATIN')) or new in "'\"-.,:;!?‘’“”«»–—…°"
    if not target or not source.CORRUPTION.search(old):return False
    letters=re.findall(r'[A-Za-z]',old)
    if not letters:return True
    # Deeply corrupted encodings sometimes contain an isolated ASCII carrier.
    # Never learn a template containing an ordinary word or boundary letter.
    return (len(old)>=12 and len(source.CORRUPTION.findall(old))>=3
            and 0<len(letters)<=32 and set(letters)<=set('eE') and len(letters)/len(old)<=.1
            and not re.search(r'[A-Za-z]{2}',old))


def restore(text,mapping):
    safe=[x for x in mapping if allowed_artifact(x['before'],x['after']) and x.get('occurrences',0)>=10
          and len(set(x.get('independent_videos',[])))>=3]
    if not safe:return text,dict(accepted=False,reason='no_independent_mapping')
    lookup={x['before']:x['after'] for x in safe};pattern=re.compile('|'.join(re.escape(x) for x in sorted(lookup,key=len,reverse=True)))
    used=Counter();carriers=Counter()
    def substitute(match):
        old=match[0];used[old]+=1
        for char in re.findall(r'[A-Za-z]',old):carriers[char]+=1
        return lookup[old]
    candidate=pattern.sub(substitute,text);strong=len(source.CORRUPTION.findall(text));remaining=len(source.CORRUPTION.findall(candidate))
    changes=sum(used.values());accepted=(changes>0 and (strong>0 or changes>=10 and len(used)>=2)
                                      and remaining==0 and not re.search(r'[\u2500-\u259f]|Ã[^\x00-\x7f]|Â[^\x00-\x7f]',candidate))
    if re.findall(r'\d+',candidate)!=re.findall(r'\d+',text):raise RuntimeError('Numeric content changed')
    # Ordinary ASCII content outside demonstrated encoding spans is immutable.
    expected=pattern.sub(lambda m:re.sub(r'[A-Za-z]','',m[0]),text)
    if re.sub(r'[^A-Za-z0-9]','',expected)!=re.sub(r'[^A-Za-z0-9]','',candidate):raise RuntimeError('Unaccounted ASCII change')
    proof=dict(accepted=accepted,substitutions=changes,remaining_encoding_signals=remaining,
               numeric_content_preserved=True,ascii_carriers_removed=dict(carriers),
               applied_templates=[dict(before=k,after=lookup[k],count=v) for k,v in used.items()])
    return (candidate if accepted else text),proof
