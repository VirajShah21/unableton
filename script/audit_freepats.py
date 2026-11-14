#!/usr/bin/env python3
"""Explicit network audit; never run by build/test or application startup.

Discover full-quality SF2 banks, retain downloads in .cache, pin exact content,
and inspect SF2 preset/key mappings. Native rendering is a separate audit step.
"""
import concurrent.futures
import hashlib
import html
import json
from pathlib import Path
import re
import struct
import subprocess
import urllib.parse
import urllib.request
from html.parser import HTMLParser

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / '.cache' / 'catalog-audit'
BASE = 'https://freepats.zenvoid.org/'

def fetch(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'Unableton-catalog-audit/1.0'}), timeout=120)

def plain(value):
    return re.sub(r'\s+', ' ', html.unescape(re.sub('<[^>]+>', ' ', value))).strip()

def discover():
    home = fetch(BASE).read().decode()
    pages = sorted(set(urllib.parse.urljoin(BASE, x) for x in re.findall(r'href="([^"]+\.html)"', home) if not x.startswith('/')))
    candidates, exclusions = [], []
    for page in pages:
        try: content = fetch(page).read().decode()
        except Exception as error:
            exclusions.append({'sourceURL': page, 'reason': 'Source unavailable: '+str(error)}); continue
        if '/SoundSets/' in page:
            exclusions.append({'sourceURL': page, 'reason': 'Overlapping General MIDI collection; individual banks are cataloged.'})
            continue
        parts = re.split(r'<h3\b[^>]*>(.*?)</h3>', content, flags=re.S)
        found = False
        for n in range(1, len(parts), 2):
            title, section = plain(parts[n]), parts[n+1]
            rows = re.findall(r'<tr\b[^>]*>(.*?)</tr>', section, re.S)
            for row in rows:
                if not re.search(r'formatSF2', row) or re.search('Small size', plain(row), re.I): continue
                link = re.search(r'href="([^"]+)"', row)
                if not link: continue
                url = urllib.parse.urljoin(page, html.unescape(link[1]))
                version = re.search(r'Version\s+([^<]+)', section)
                license_section = next((x for x in re.findall(r'<p\b[^>]*>.*?</p>', section, re.S) if 'Published under' in plain(x)), section)
                license_links = re.findall(r'href="([^"]*(?:creativecommons\.org|gnu\.org/licenses)[^"]*)"', license_section)
                if not license_links:
                    exclusions.append({'sourceURL': page, 'name': title, 'reason': 'No explicit supported license link in instrument section.'});continue
                license_url = license_links[0].replace('http:', 'https:')
                license_id = 'CC0-1.0' if '/zero/1.0' in license_url else 'CC-BY-3.0' if '/by/3.0' in license_url else 'CC-BY-4.0' if '/by/4.0' in license_url else 'GPL-3.0-or-later WITH FreePats-exception' if 'gnu.org/licenses/gpl-3' in license_url and 'special exception' in plain(section) else None
                if not license_id:
                    exclusions.append({'sourceURL': page, 'name': title, 'reason': 'License requires separate review.'});continue
                description_section = section.split('<table')[0]
                paragraphs = [plain(x) for x in re.findall(r'<p\b[^>]*>(.*?)</p>', description_section, re.S)]
                attribution = ' '.join(x for x in paragraphs if not x.startswith('Version') and not x.startswith('Published under') and not x.startswith('Photo courtesy'))
                candidates.append({'name': title, 'version': plain(version[1]) if version else 'unversioned', 'sourceURL': page, 'url': url, 'license': license_id, 'licenseURL': license_url, 'attribution': attribution, 'row': plain(row)})
                found = True
        if not found: exclusions.append({'sourceURL': page, 'reason': 'No downloadable SF2 version; SFZ-only or unavailable.'})
    return candidates, exclusions

def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
    return h.hexdigest()

def chunks(data, start, end):
    while start+8<=end:
        tag=data[start:start+4];size=struct.unpack_from('<I',data,start+4)[0]
        if start+8+size>end:raise ValueError('Invalid chunk length')
        yield tag,start+8,size
        start+=8+size+(size%2)

def inspect_sf2(path):
    data=path.read_bytes();pdta={};info={}
    if data[:4]!=b'RIFF' or data[8:12]!=b'sfbk':raise ValueError('Not SF2')
    for tag,at,size in chunks(data,12,len(data)):
        if tag!=b'LIST':continue
        for child,pos,length in chunks(data,at+4,at+size):
            if data[at:at+4]==b'pdta':pdta[child]=data[pos:pos+length]
            if data[at:at+4]==b'INFO':info[child.decode(errors='replace')]=data[pos:pos+length].rstrip(b'\0').decode(errors='replace')
    def records(tag,size):
        b=pdta[tag];return [b[i:i+size] for i in range(0,len(b),size)]
    phdr=records(b'phdr',38);pbag=records(b'pbag',4);pgen=records(b'pgen',4)
    inst=records(b'inst',22);ibag=records(b'ibag',4);igen=records(b'igen',4);shdr=records(b'shdr',46)
    def zones(bags,gens,start,end,selector):
        result=[];global_range=(0,127)
        for b in range(start,end):
            first=struct.unpack_from('<H',bags[b])[0];last=struct.unpack_from('<H',bags[b+1])[0]
            sel=None;key=(0,127)
            for g in gens[first:last]:
                op,value=struct.unpack('<HH',g)
                if op==43:key=(value&255,value>>8)
                elif op==selector:sel=value
            if sel is None:global_range=key
            else:result.append((sel,(max(key[0],global_range[0]),min(key[1],global_range[1]))))
        return result
    result=[]
    for i,p in enumerate(phdr[:-1]):
        name=p[:20].rstrip(b'\0').decode(errors='replace');program,bank,start=struct.unpack_from('<HHH',p,20)
        end=struct.unpack_from('<H',phdr[i+1],24)[0];pitches=set();sample_names={}
        for instrument,prange in zones(pbag,pgen,start,end,41):
            if instrument+1>=len(inst):continue
            first=struct.unpack_from('<H',inst[instrument],20)[0];last=struct.unpack_from('<H',inst[instrument+1],20)[0]
            for sample_id,irange in zones(ibag,igen,first,last,53):
                covered=range(max(prange[0],irange[0]),min(prange[1],irange[1])+1);pitches.update(covered)
                sample_name=shdr[sample_id][:20].rstrip(b'\0').decode(errors='replace')
                for pitch in covered:sample_names.setdefault(pitch,set()).add(sample_name)
        if pitches:result.append({'name':name,'program':program,'bank':bank,'pitches':sorted(pitches),'sampleNames':{str(k):sorted(v) for k,v in sample_names.items()}})
    return result,info

def acquire(candidate):
    result=dict(candidate)
    try:
        filename=urllib.parse.unquote(urllib.parse.urlparse(candidate['url']).path.rsplit('/',1)[-1]);archive=CACHE/filename
        if not archive.exists():
            temp=archive.with_suffix(archive.suffix+'.download')
            with fetch(candidate['url']) as response,temp.open('wb') as output:
                while block:=response.read(1024*1024):output.write(block)
            temp.replace(archive)
        if filename.endswith('.sf2'):member=filename;target=archive
        else:
            members=subprocess.check_output(['/usr/bin/tar','-tf',str(archive)],text=True).splitlines()
            sf2=[x for x in members if x.lower().endswith('.sf2')]
            if len(sf2)!=1:raise ValueError('Expected one SF2: '+repr(sf2))
            member=sf2[0];target=CACHE/(hashlib.sha256(candidate['url'].encode()).hexdigest()[:12]+'.sf2')
            if not target.exists():
                with target.open('wb') as output:subprocess.run(['/usr/bin/tar','-xOf',str(archive),member],stdout=output,check=True)
        presets,info=inspect_sf2(target)
        if not presets:raise ValueError('No playable presets')
        result.update(archiveSHA256=digest(archive),sha256=digest(target),downloadBytes=archive.stat().st_size,installedBytes=target.stat().st_size,member=member,fileName=Path(member).name,presets=presets,info=info,localPath=str(target))
        print('Audited '+candidate['name']+' ('+str(len(presets))+' presets)',flush=True)
    except Exception as e:result['error']=str(e);print('FAILED '+candidate['name']+': '+str(e),flush=True)
    return result

if __name__=='__main__':
    CACHE.mkdir(parents=True,exist_ok=True)
    candidates,exclusions=discover()
    (CACHE/'candidates.json').write_text(json.dumps(candidates,indent=2))
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:results=list(pool.map(acquire,candidates))
    (CACHE/'audit.json').write_text(json.dumps({'banks':results,'exclusions':exclusions},indent=2))
    print('Completed '+str(len(results))+' candidates',flush=True)
