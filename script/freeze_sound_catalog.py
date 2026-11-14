#!/usr/bin/env python3
"""Freeze successful explicit FreePats audits into the shipped metadata catalog."""
import datetime
import json
import platform
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
AUDIT = ROOT / '.cache/catalog-audit/native-audit.json'
DESTINATION = ROOT / 'Sources/UnabletonCore/Resources/sound-library.json'

def slug(value):
    return re.sub(r'[^a-z0-9]+', '-', value.lower()).strip('-')

def presentation(item):
    page, title = item['sourceURL'], item['name']
    if 'PickedBass' in item['url']: return 'Bass guitar — pick', 'Guitars', 'guitars', ['bass'], 'Picked electric bass guitar.'
    if '/ElectricGuitar/' in page:
        name = {'FSBS Electric Guitar Clean #1':'Electric guitar — clean', 'FSBS Electric Guitar Clean #2 (Jazz)':'Electric guitar — jazz', 'FSBS Electric Guitar Direct':'Electric guitar — direct', 'FSBS Electric Guitar Distorted #1':'Electric guitar — distorted 1','FSBS Electric Guitar Distorted #2':'Electric guitar — distorted 2'}.get(title,title)
        description = name+'.'
        if 'Direct' in title: description += ' Raw direct-input recording; use effects for an amplified character.'
        return name,'Guitars','guitars',['melody','accompaniment'],description
    if '/Guitar/' in page or '/GuitarFamily/' in page:return title,'Guitars','guitars',['melody','accompaniment'],title+'.'
    if '/Piano/' in page or '/ElectricPiano/' in page:return title,'Pianos','pianokeys',['melody','harmony','accompaniment'],title+'.'
    if '/Organ/' in page:return title,'Organs','pianokeys',['harmony','melody','accompaniment'],title+'.'
    if '/OrchestralStrings/' in page:return title,'Strings','music.note',['melody','harmony','accompaniment'],title+'.'
    if '/Reed/' in page or '/Wind/' in page:return title,'Winds','music.note',['melody','countermelody'],title+'.'
    if '/Synthesizer/' in page:
        role = ['bass'] if 'Bass' in title and 'Lead' not in title else ['harmony','texture'] if any(x in title for x in ['Pad','Strings','Sweep','New Age','Soundtrack','Goblins','Sci-Fi','Crystal']) else ['melody','countermelody']
        return title,'Synthesizers','waveform',role,'Sampled '+title.lower()+'. Parameters differ from the built-in procedural synthesizers.'
    if '/Percussion/' in page:
        role=['drums'] if 'synthesizer' in title else ['percussion']
        description=title+'. Use native MIDI note numbers, not General MIDI drum mapping.'
        if 'synthesizer' in title: description += ' Keys: 48 kick 1; 49 kick 2; 50 snare 1; 51 snare 2; 52 closed hi-hat 1; 53 closed hi-hat 2; 54 open hi-hat; 55 cymbal 1; 56 cymbal 2; 57–58 low tom; 59–60 mid tom; 61–62 high tom; 63 clap; 64 short shaker; 65 long shaker; 66 claves.'
        if 'World' in title: description += ' Keys: 48 cajón 1; 49 cajón 3; 50 cajón 2; 51 muted bongo; 52 high bongo; 53 low bongo; 54 slow egg shaker; 55 fast egg shaker; 56 soft egg shaker; 57 tambourine; 58 fast tambourine; 59 clap; 60 claves; 61 castanets; 62 conga; 63 high conga; 64 low conga; 65 muted conga; 66 low muted conga; 67–68 maracas; 69 darbuka doom; 70 darbuka tak; 71 darbuka pa.'
        return title,'Drums' if 'synthesizer' in title else 'Percussion','drum',role,description
    return title,'Percussion','music.note',['melody','percussion'],title+'.'

def main():
    audit=json.loads(AUDIT.read_text())
    legacy=json.loads((ROOT/'Resources/factory-manifest.json').read_text())
    legacy_by_url={x['url']:x for x in legacy}
    existing=json.loads(DESTINATION.read_text())
    legacy_metadata={x['id']:x for x in existing['banks'] if x['id'] in {x['id'] for x in legacy}}
    banks=[];presets=[];proof=[];warnings=[];exclusions=list(audit['exclusions'])
    for item in audit['banks']:
        old=legacy_by_url.get(item['url'])
        legacy_warning=old is not None and bool(item.get('nativeSilentPitches'))
        if not item.get('nativeValidated') and not legacy_warning:
            exclusions.append({'sourceURL':item['sourceURL'],'name':item['name'],'version':item['version'],'url':item['url'],'archiveSHA256':item.get('archiveSHA256'),'sha256':item.get('sha256'),'reason':item.get('nativeError',item.get('error','Native rendering not validated'))})
            continue
        if legacy_warning:
            mapping={35:48,36:48,37:50,38:50,39:51,40:50,41:64,42:52,43:63,44:52,45:62,46:53,47:61,48:61,49:58,50:61,51:54,52:60,53:55,55:58,56:55,57:58,59:54}
            warnings.append(dict(bankID=old['id'],instrumentID='sampled.drums',reason=item['nativeError'],status='grandfathered-partial-compatibility',silentNativePitches=item['nativeSilentPitches'],silentProjectPitches=[key for key,value in mapping.items() if value in item['nativeSilentPitches']]))
        stem=item['url'].rsplit('/',1)[-1].split('-SF2')[0]
        bank_id=old['id'] if old else 'freepats.'+slug(stem)
        bank={key:item[key] for key in ['version','url','archiveSHA256','member','sha256','downloadBytes','installedBytes','license','licenseURL','attribution','sourceURL']}
        bank.update(id=bank_id,sourceID='freepats',fileName=old['file'] if old else item['fileName'])
        bank['attribution']=re.sub(r'^Photo courtesy.*?license\s*', '', bank['attribution'])
        if old:
            for key in ['archiveSHA256','sha256','member','version']:
                if bank[key]!=old[key]:raise RuntimeError('Legacy artifact changed: '+bank_id+' '+key)
            bank['attribution']=legacy_metadata[bank_id]['attribution']
        banks.append(bank)
        for native in item['presets']:
            proof.append({'bankID':bank_id,'program':native['program'],'bank':native['bank'],'minimumPitch':min(native['pitches']),'maximumPitch':max(native['pitches']),'nativeRender':native['nativeRender'],'fullyValidated':bool(item.get('nativeValidated'))})
            if old:continue
            name,category,symbol,roles,description=presentation(item)
            instrument_id=bank_id
            if len(item['presets'])>1:
                instrument_id+='.'+str(native['bank'])+'.'+str(native['program'])
                name+=' — '+native['name']
            notes=native['pitches']
            # Sparse keys must stay sparse; dense melodic ranges need no verbose list.
            supported=notes if notes!=list(range(min(notes),max(notes)+1)) or category in ['Drums','Percussion'] else None
            gm_match=re.search(r'General MIDI instrument\s*#(\d+)', item.get('attribution',''), re.I)
            gm_program=int(gm_match[1])-1 if gm_match and 1<=int(gm_match[1])<=128 else None
            presets.append(dict(gmProgram=gm_program,id=instrument_id,name=name,category=category,symbol=symbol,soundFontFileName=item['fileName'],defaults={},minimumPitch=min(notes),maximumPitch=max(notes),supportedPitches=supported,soundBankID=bank_id,program=native['program'],bank=native['bank'],pitchMap=None,description=description,roles=roles))
    missing={x['id'] for x in legacy}-{x['id'] for x in banks}
    if missing:raise RuntimeError('Legacy banks failed audit: '+repr(missing))
    DESTINATION.write_text(json.dumps(dict(banks=banks,presets=presets),indent=2,ensure_ascii=False)+'\n')
    report=dict(auditedOn=datetime.date.today().isoformat(),platform={'macOS':platform.mac_ver()[0],'architecture':platform.machine()},method='Pinned archive + SF2 SHA-256, parsed preset/sample key zones, Fresh AVAudioUnitSampler graph and production-style pre-render MIDI scheduling for each low/middle/high supported key at velocity 100; all legacy Muldjord mapped native keys tested. Numerical non-silence, not a listening judgment.',banks=len(banks),downloadBytes=sum(x['downloadBytes'] for x in banks),installedBytes=sum(x['installedBytes'] for x in banks),presets=proof,legacyCompatibilityWarnings=warnings,exclusions=exclusions)
    (ROOT/'docs/sound-library-audit.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
    rows=['# Sound library notices','','Unableton code is Apache 2.0. Six built-in procedural instruments use Unableton DSP and contain no third-party samples. Sampled banks are optional downloads, not bundled with the app. Each bank retains its own license.','','The reviewed versions, exact archive/member hashes and source URLs are pinned in the sound-library catalog. The original five instrument identities and versions are retained. No endorsement by the sample authors is implied.','','| Bank | Version | License | Attribution |','| --- | --- | --- | --- |']
    for bank in banks:
        name=next(x['name'] for x in audit['banks'] if x['url']==bank['url'])
        credit=bank['attribution'].replace('|','\\|')
        rows.append(f"| [{name}]({bank['sourceURL']}) | {bank['version']} | [{bank['license']}]({bank['licenseURL']}) | {credit} |")
    rows+=['','Legacy MuldjordKit compatibility: the native sampler renders only the kick/snare mappings reliably in the current audit. Other mapped notes produced silence. The bank remains listed to preserve existing songs and is not marked fully validated. See docs/sound-library-audit.json for exact keys.','','The steel-string guitar uses GPL version 3 or later with the FreePats sample exception; see [FreePats licensing](https://freepats.zenvoid.org/licenses.html#GPL_exception) and the bank’s included license files. Attribution-licensed banks preserve their creator credits above. Photo licenses shown on source pages are separate from the sound-bank license; Unableton does not download or distribute those photos.','']
    (ROOT/'THIRD_PARTY_NOTICES.md').write_text('\n'.join(rows))
    print(f'Frozen {len(banks)} banks, {len(presets)+5} sampled instruments, {len(exclusions)} exclusions.')

if __name__=='__main__':main()
