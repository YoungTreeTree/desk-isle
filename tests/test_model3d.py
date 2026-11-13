"""Portable renderer checks with original synthetic geometry, no licensed model required."""
import copy
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]


def fixture():
    binary=bytearray()
    def floats(values):
        offset=len(binary);binary.extend(struct.pack('<'+'f'*len(values),*values));return offset
    positions=floats([-1,0,0,1,0,0,0,2,0])
    normals=floats([0,0,1]*3)
    indices=len(binary);binary.extend(struct.pack('<3I',0,1,2))
    times=floats([0,1]);scales=floats([0,0,0,1,1,1])
    metadata={"v":1,"vertices":3,"triangles":1,
              "nodes":[{"parent":-1,"p":[0,0,.85],"q":[0,0,0,1],"s":[1,1,1],"weights":[]}],
              "meshes":[{"node":0,"material":0,"count":3,"position":positions,"normal":normals,
                         "indices":indices,"indexCount":3,"uv":-1,"morphs":[]}],
              "materials":[{"color":[.2,.4,.9],"texture":-1,"doubleSided":True}],"textures":[],
              "clips":[{"name":"appear","duration":1,"tracks":[{"node":0,"path":2,"size":3,"count":2,
                          "times":times,"values":scales,"step":False}]}]}
    return metadata,binary


def pack(metadata,binary):
    encoded=json.dumps(metadata,separators=(',',':')).encode()
    encoded+=b' '*(-len(encoded)%4)
    return struct.pack('<4sIII',b'D3M1',1,len(encoded),len(binary))+encoded+binary


def main():
    idf=Path(os.environ['IDF_PATH'])
    cjson=idf/'components/json/cJSON'
    with tempfile.TemporaryDirectory() as directory:
        path=Path(directory);exe=path/'test'
        subprocess.run(['clang','-std=c11','-O1','-g','-Wall','-Wextra','-Werror','-Wno-deprecated-declarations',
            '-fsanitize=address,undefined','-I',str(ROOT/'main/model3d'),'-I',str(cjson),
            str(ROOT/'main/model3d/scene3d.c'),str(ROOT/'tests/model3d_test.c'),str(cjson/'cJSON.c'),'-o',str(exe)],check=True)
        metadata,binary=fixture();model=path/'fixture.d3m';model.write_bytes(pack(metadata,binary))
        subprocess.run([str(exe),str(model)],check=True)
        cases=[]
        bad=copy.deepcopy(metadata);bad['nodes'][0]['parent']=0;cases.append((bad,binary))
        bad=copy.deepcopy(metadata);bad['meshes'][0]['position']=1;cases.append((bad,binary))
        bad=copy.deepcopy(metadata);bad['meshes'][0]['count']=150001;cases.append((bad,binary))
        bad=copy.deepcopy(metadata);bad['materials'][0]['texture']=0;cases.append((bad,binary))
        bad=copy.deepcopy(metadata);bad['clips'][0]['tracks'][0]['node']=1;cases.append((bad,binary))
        bad_binary=bytearray(binary);struct.pack_into('<I',bad_binary,metadata['meshes'][0]['indices'],99);cases.append((metadata,bad_binary))
        bad_binary=bytearray(binary);struct.pack_into('<f',bad_binary,0,float('nan'));cases.append((metadata,bad_binary))
        bad_binary=bytearray(binary);struct.pack_into('<2f',bad_binary,metadata['clips'][0]['tracks'][0]['times'],1,0);cases.append((metadata,bad_binary))
        for i,(m,b) in enumerate(cases):
            candidate=path/f'invalid-{i}.d3m';candidate.write_bytes(pack(m,b))
            subprocess.run([str(exe),str(candidate),'--reject'],check=True)
        print('PASS synthetic renderer, allocation failures, replay, portrait/landscape, and 8 corrupt packs; ASan/UBSan clean')


if __name__=='__main__':
    main()
