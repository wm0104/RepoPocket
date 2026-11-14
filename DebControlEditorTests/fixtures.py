#!/usr/bin/env python3
import io, gzip, tarfile, pathlib, sys, hashlib, lzma, subprocess
root=pathlib.Path(__file__).parent
fixtures=root/'fixtures'; fixtures.mkdir(exist_ok=True)
control='Package: old.test\nVersion: 1.0\nName: 中文显示名\nAuthor: Original Author\nArchitecture: iphoneos-arm64e\nDescription: Old summary\n second line\n .\n last\nMaintainer: Old <old@example.org>\nDepends: substrate\n'.encode()
def tar(bad=False):
    out=io.BytesIO()
    with tarfile.open(fileobj=out, mode='w',format=tarfile.USTAR_FORMAT) as t:
        for name,body,kind in [('./',b'',tarfile.DIRTYPE),('./control',control,tarfile.REGTYPE),('./postinst',b'#!/bin/sh\n',tarfile.REGTYPE)]:
            x=tarfile.TarInfo(name);x.type=kind;x.size=len(body);x.mtime=42;x.mode=0o755 if name.endswith('postinst') else 0o644;t.addfile(x,io.BytesIO(body))
        if bad:
            x=tarfile.TarInfo('./evil');x.type=tarfile.SYMTYPE;x.linkname='/etc/passwd';t.addfile(x)
    return out.getvalue()
def member(name,body):
    h=f'{name+"/":<16}{0:<12}{0:<6}{0:<6}{100644:<8}{len(body):<10}`\n'.encode()
    assert len(h)==60
    return h+body+(b'\n' if len(body)%2 else b'')
def deb(suffix,bad=False):
    payload=tar(bad)
    # Exercise legal trailing paragraph separators on real editing paths.
    if suffix in ('xz', 'zst'):
        out=io.BytesIO()
        with tarfile.open(fileobj=io.BytesIO(payload)) as src, tarfile.open(fileobj=out, mode='w', format=tarfile.USTAR_FORMAT) as dst:
            for item in src:
                body=src.extractfile(item).read() if item.isfile() else b''
                if item.name.endswith('control'): body += b'\n\n'; item.size=len(body)
                dst.addfile(item, io.BytesIO(body) if item.isfile() else None)
        payload=out.getvalue()
    if suffix=='gz':payload=gzip.compress(payload,mtime=0)
    elif suffix=='xz':payload=lzma.compress(payload)
    elif suffix=='zst':payload=subprocess.run(['zstd','-q','-c','--check'],input=payload,stdout=subprocess.PIPE,check=True).stdout
    name='control.tar'+('.'+suffix if suffix else '')
    return b'!<arch>\n'+member('debian-binary',b'2.0\n')+member('_extra',b'123')+member(name,payload)+member('data.tar.gz',gzip.compress(tar(),mtime=0))
for name,suffix,bad in [('plain','',False),('gzip','gz',False),('symlink','gz',True),('xz','xz',False),('zst','zst',False)]:
    (fixtures/(name+'.deb')).write_bytes(deb(suffix,bad))
_corrupt=bytearray(deb('xz')); _offset=_corrupt.index(b'\xfd7zXZ\x00'); _corrupt[_offset+12] ^= 0xff
(fixtures/'corrupt.deb').write_bytes(_corrupt)
(fixtures/'truncated.deb').write_bytes(deb('gz')[:-10])
# Permission fixtures exercise production Swift repair, not a reimplementation.
def permission_deb(suffix, mode=0, bad=None):
    out=io.BytesIO()
    with tarfile.open(fileobj=out, mode='w', format=tarfile.USTAR_FORMAT) as t:
        for name,body in [('./',b''),('./control',control),('./postinst',b'#!/bin/sh\n'),('./custom',b'keep')]:
            x=tarfile.TarInfo(name); x.mode=mode if name!='./custom' else 0o600
            x.type=tarfile.DIRTYPE if name=='./' or (bad=='directory' and name=='./postinst') else tarfile.REGTYPE
            x.size=0 if x.isdir() else len(body); t.addfile(x, io.BytesIO(body) if x.isfile() else None)
    payload=out.getvalue()
    if bad=='mode':
        payload=bytearray(payload); payload[100:108]=b'00000x0\0'; payload[148:156]=b'        '
        payload[148:156]=f'{sum(payload[:512]):07o}\0'.encode(); payload=bytes(payload)
    if suffix=='gz': payload=gzip.compress(payload,mtime=0)
    elif suffix=='xz': payload=lzma.compress(payload)
    elif suffix=='zst': payload=subprocess.run(['zstd','-q','-c'],input=payload,stdout=subprocess.PIPE,check=True).stdout
    return b'!<arch>\n'+member('debian-binary',b'2.0\n')+member('_extra',b'123')+member('control.tar'+('.'+suffix if suffix else ''),payload)+member('data.tar.gz',gzip.compress(tar(),mtime=0))
for name,suffix in [('plain',''),('gzip','gz'),('xz','xz'),('zst','zst')]:
    (fixtures/('zero-'+name+'.deb')).write_bytes(permission_deb(suffix))
(fixtures/'nonzero.deb').write_bytes(permission_deb('gz',0o700))
for bad in ['mode','directory']:
    (fixtures/(bad+'.deb')).write_bytes(permission_deb('gz',bad=bad))
(fixtures/'special.deb').write_bytes(permission_deb('gz',0o4755))
(fixtures/'unsupported.deb').write_bytes(b'!<arch>\n'+member('debian-binary',b'2.0\n')+member('control.tar.bz2',__import__('bz2').compress(tar()))+member('data.tar.gz',gzip.compress(tar())))
if len(sys.argv)>1:
    results=pathlib.Path(sys.argv[1]);
    def parse(path):
        b=path.read_bytes();assert b.startswith(b'!<arch>\n');p=8;items={}
        while p<len(b):
            h=b[p:p+60];assert len(h)==60 and h[-2:]==b'`\n';n=h[:16].strip().removesuffix(b'/').decode();size=int(h[48:58]);items[n]=(b[p:p+60+size+size%2],b[p+60:p+60+size]);p+=60+size+size%2
        return items
    for name in ('gzip','plain','xz','zst'):
        original=parse(fixtures/(name+'.deb'));edited=parse(results/(name+'-edited.deb'))
        assert set(edited)==(set(original)-{'control.tar.xz','control.tar.zst'} | ({'control.tar.gz'} if name in ('xz','zst') else set()))
        for key in original:
            if key.startswith('control.tar'):continue
            assert original[key]==edited[key]
        assert hashlib.sha256(original['data.tar.gz'][1]).digest()==hashlib.sha256(edited['data.tar.gz'][1]).digest()
        k='control.tar'+('.gz' if name!='plain' else '')
        data=gzip.decompress(edited[k][1]) if name!='plain' else edited[k][1]
        with tarfile.open(fileobj=io.BytesIO(data)) as t:
            c=t.extractfile('./control').read().decode()
            assert 'Package: new.test\n' in c and 'Version: 2:3.4-1\n' in c
            assert 'Description: New summary\n continued\n .\n last\n' in c
            assert 'Maintainer: New <new@example.org>\n' in c
            assert 'Name: 新名称\n' in c and 'Author: New Author\n' in c and 'Architecture: iphoneos-arm64e\n' in c
            assert t.getmember('./postinst').mode == 0o755
            assert 'Depends: substrate\n' in c and 'Section: Tweaks\n' in c
            assert t.extractfile('./postinst').read()==b'#!/bin/sh\n'
        print('PASS independent archive verification',name)

    for name in ('plain','gzip','xz','zst'):
        before=parse(fixtures/('zero-'+name+'.deb'))
        for action in ['repaired','edited']:
            after=parse(results/('zero-'+name+'-'+action+'.deb'))
            for key in before:
                if not key.startswith('control.tar'): assert before[key]==after[key]
            key=next(k for k in after if k.startswith('control.tar'))
            payload=after[key][1]; payload=gzip.decompress(payload) if key.endswith('.gz') else payload
            with tarfile.open(fileobj=io.BytesIO(payload)) as t:
                assert t.getmember('.').mode==0o755
                assert t.getmember('./control').mode==0o644
                assert t.getmember('./postinst').mode==0o755
                assert t.getmember('./custom').mode==0o600
        print('PASS zero-mode repair/edit and exact non-control preservation',name)
