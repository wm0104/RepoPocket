import pathlib, subprocess, gzip, tarfile, io, hashlib
root=pathlib.Path('/tmp/rpp-private-inputs')
def ar(p):
    b=p.read_bytes(); pos=8; members={}; assert b[:8]==b'!<arch>\n'
    while pos<len(b):
        h=b[pos:pos+60]; n=h[:16].strip().rstrip(b'/').decode(); size=int(h[48:58]); end=pos+60+size+size%2
        members[n]=(b[pos:end],b[pos+60:pos+60+size]);pos=end
    assert pos==len(b)
    return members
for directory in root.iterdir():
    for source in directory.iterdir():
        output=pathlib.Path('/tmp/rpp-private-outputs')/directory.name/source.name
        before=ar(source);after=ar(output)
        data=next(n for n in before if n.startswith('data.tar'))
        assert before[data][0]==after[data][0]
        assert set(after)==(set(before)-{'control.tar.xz','control.tar.zst'}|{'control.tar.gz'})
        with tarfile.open(fileobj=io.BytesIO(gzip.decompress(after['control.tar.gz'][1]))) as t:
            control=next(x for x in t if x.name.lstrip('./')=='control')
            assert b'RepoPocket local verification' in t.extractfile(control).read()
        repaired=pathlib.Path('/tmp/rpp-private-repaired')/directory.name/source.name
        for checked in [output] + ([repaired] if repaired.exists() else []):
            members=ar(checked)
            for key in before:
                if not key.startswith('control.tar'): assert before[key]==members[key]
            k=next(k for k in members if k.startswith('control.tar'))
            payload=members[k][1]; payload=gzip.decompress(payload) if k.endswith('.gz') else payload
            with tarfile.open(fileobj=io.BytesIO(payload)) as t:
                for entry in t:
                    n=entry.name.lstrip('./')
                    if n=='control': assert entry.mode != 0
                    if n in ['preinst','postinst','prerm','postrm','config']: assert entry.isfile() and entry.mode != 0
                    if n=='': assert entry.mode != 0
        # Preserve original archive modes: some real control members are not readable by
        # the runner user after dpkg extracts them. Verify as root without installing.
        subprocess.run(['sudo','-n','dpkg-deb','--info',str(output)],stdout=subprocess.DEVNULL,check=True)
        print('PASS independent Python / dpkg-deb local sample',directory.name, 'data member sha256',hashlib.sha256(before[data][0]).hexdigest())
