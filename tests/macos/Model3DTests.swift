import XCTest
@testable import DeskIsle

final class Model3DTests: XCTestCase {
    private func fixture() throws -> Data {
        var bin=Data()
        for value:Float in [-1,0,0,1,0,0,0,2,0, 0,0,1,0,0,1,0,0,1] {
            withUnsafeBytes(of:value.bitPattern.littleEndian){bin.append(contentsOf:$0)}
        }
        for value:UInt32 in [0,1,2] {withUnsafeBytes(of:value.littleEndian){bin.append(contentsOf:$0)}}
        let json:[String:Any]=[
            "asset":["version":"2.0"],"buffers":[["byteLength":bin.count]],
            "bufferViews":[["buffer":0,"byteOffset":0,"byteLength":36],["buffer":0,"byteOffset":36,"byteLength":36],["buffer":0,"byteOffset":72,"byteLength":12]],
            "accessors":[["bufferView":0,"componentType":5126,"count":3,"type":"VEC3"],
                         ["bufferView":1,"componentType":5126,"count":3,"type":"VEC3"],
                         ["bufferView":2,"componentType":5125,"count":3,"type":"SCALAR"]],
            "nodes":[["mesh":0]],"meshes":[["primitives":[["attributes":["POSITION":0,"NORMAL":1],"indices":2]]]],
            "scenes":[["nodes":[0]]],"scene":0
        ]
        var encoded=try JSONSerialization.data(withJSONObject:json)
        while encoded.count%4 != 0{encoded.append(32)}
        var data=Data()
        for v in [UInt32(0x46546c67),2,UInt32(28+encoded.count+bin.count),UInt32(encoded.count),0x4e4f534a]{withUnsafeBytes(of:v.littleEndian){data.append(contentsOf:$0)}}
        data.append(encoded)
        for v in [UInt32(bin.count),0x004e4942]{withUnsafeBytes(of:v.littleEndian){data.append(contentsOf:$0)}}
        data.append(bin);return data
    }
    func testBuiltInCatalogHasOnlyAnimatedLowPolyBB8() throws {
        XCTAssertEqual(BuiltInModel3D.allCases,[.bb8])
        XCTAssertNotNil(BuiltInModel3D.bb8.previewURL)
        let file=try BuiltInModel3D.bb8.load()
        XCTAssertEqual(file.name,"BB8");XCTAssertEqual(file.triangles,7521)
        XCTAssertEqual(file.vertices,4057);XCTAssertLessThan(file.pack.count,2*1024*1024)
        let size=file.pack.withUnsafeBytes { Int(UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:8,as:UInt32.self))) }
        let metadata=try XCTUnwrap(JSONSerialization.jsonObject(with:file.pack.subdata(in:16..<16+size)) as? [String:Any])
        let clips=try XCTUnwrap(metadata["clips"] as? [[String:Any]])
        XCTAssertEqual(clips.count,1);XCTAssertEqual(clips[0]["name"] as? String,"idle")
        XCTAssertEqual(clips[0]["duration"] as? Double,12)
        XCTAssertEqual((clips[0]["tracks"] as? [Any])?.count,4)
        XCTAssertEqual((metadata["textures"] as? [Any])?.count,2)
    }

    func testPackagedModelsResolveInsideRelocatedAppAndFailWithoutResources() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app=directory.appendingPathComponent("Relocated.app")
        let resources=app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at:resources,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let info:[String:Any] = ["CFBundleIdentifier":"deskisle.test.model-resources", "CFBundlePackageType":"APPL", "CFBundleExecutable":"DeskIsle"]
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0)
            .write(to:app.appendingPathComponent("Contents/Info.plist"))
        let application=try XCTUnwrap(Bundle(url:app))
        XCTAssertThrowsError(try BuiltInModel3D.resources(in:application))
        let source=try BuiltInModel3D.resources()
        try FileManager.default.copyItem(at:source.bundleURL,to:resources.appendingPathComponent("DeskIsle_DeskIsle.bundle"))
        let relocated=try BuiltInModel3D.resources(in:application)
        let url=try BuiltInModel3D.bb8.modelURL(in:relocated)
        XCTAssertTrue(url.path.hasPrefix(app.path))
        XCTAssertEqual(try Data(contentsOf:url),try Data(contentsOf:BuiltInModel3D.bb8.modelURL(in:source)))
        try FileManager.default.removeItem(at:url)
        XCTAssertThrowsError(try Data(contentsOf:BuiltInModel3D.bb8.modelURL(in:relocated)))
    }

    func testCompactModelMovesAndKeepsSizeAcrossOrientations() throws {
        var layout=ScreenLayout(panel:.deskIsle,direction:.left,components:[])
        layout.components=[try XCTUnwrap(WidgetRegistry.model3D.makeComponent(in:layout))]
        layout.move(Component.model3DID,to:GridPosition(column:8,row:4))
        XCTAssertEqual(layout.model3D?.x,320);XCTAssertEqual(layout.model3D?.y,160)
        for direction in ScreenDirection.allCases {
            XCTAssertTrue(layout.changeDirection(to:direction));XCTAssertTrue(layout.isValid)
            XCTAssertEqual(layout.model3D?.width,320);XCTAssertEqual(layout.model3D?.height,480)
        }
        layout.components[0].width -= 40;XCTAssertFalse(layout.isValid)
    }
    func testLegacyFullScreenModelCanLoadRotateAndResize() {
        var layout=ScreenLayout(panel:.deskIsle,direction:.left,
            components:[Component(id:Component.model3DID,x:0,y:0,width:1280,height:720)])
        XCTAssertTrue(layout.isValid)
        XCTAssertTrue(layout.changeDirection(to:.portrait))
        XCTAssertEqual(layout.model3D?.width,720);XCTAssertEqual(layout.model3D?.height,1280)
        layout.resize(Component.model3DID,to:GridSize(columns:8,rows:12))
        XCTAssertTrue(layout.isValid);XCTAssertEqual(layout.model3D?.width,320);XCTAssertEqual(layout.model3D?.height,480)
    }
    func testImporterRetainsSourceAndCreatesIndependentRuntimeAsset() throws {
        let data=try fixture(),prepared=try Model3DImporter.convert(data)
        XCTAssertEqual(prepared.triangles,1);XCTAssertEqual(prepared.vertices,3)
        XCTAssertEqual(prepared.pack.prefix(4),Data("D3M1".utf8));XCTAssertNotEqual(prepared.pack,data)
        XCTAssertThrowsError(try Model3DImporter.convert(data.dropLast()))
        var wrong=data;wrong[4]=1;XCTAssertThrowsError(try Model3DImporter.convert(wrong))
        XCTAssertThrowsError(try Model3DImporter.convert(Data()))
    }
    func testModelReferencesSurviveCopyRequestedSnapshotAndGarbageCollection() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("triangle.glb");try fixture().write(to:source)
        let file=try Model3DFile(from:source),store=LayoutLibraryStore(root:root.appendingPathComponent("Library"))
        let id=try store.storeModel(file)
        var layout=ScreenLayout(panel:.deskIsle,direction:.left,components:[])
        layout.components=[try XCTUnwrap(WidgetRegistry.model3D.makeComponent(in:layout))]
        let scene=LayoutScene(layout:layout,skinID:"unused",modelID:id,modelScale:1)
        let profile=SavedLayout(name:"3D",scene:scene)
        var library=LayoutLibrary();library.layouts=[profile,SavedLayout(name:"copy",scene:scene)]
        library.requested=LayoutSelection(id:profile.id,scene:scene)
        try store.save(library)
        library.layouts[0].scene.modelID=nil;library.layouts[1].scene.modelID=nil
        try store.save(library);store.collectUnusedAssets(in:library)
        XCTAssertEqual(try store.model(id).pack,file.pack)
        XCTAssertEqual(try store.load().library.requested?.scene,scene)
        var broken=scene;broken.modelID=UUID();XCTAssertThrowsError(try store.validateReferences(broken))
    }
    func testStatisticsRequireMatchingSequenceAndUsePresentationCount() {
        let line="DESKISLE_3D_STATS 1 9 1280 720 11 10 2000000 1500000 180000 136363 85936 48019 4528292 4156208 12000000 8000000 120000"
        let stats=Model3DStats(line:line,sequence:9)
        XCTAssertEqual(stats?.fps,5);XCTAssertEqual(stats?.renderOccupancy,75)
        XCTAssertEqual(stats?.triangles,85936);XCTAssertNil(Model3DStats(line:line,sequence:10))
        XCTAssertNil(Model3DStats(line:line+" invalid",sequence:9))
    }

    func testSimplificationPreservesBordersUVsMorphsAndAnimation() throws {
        let side=80, count=(side+1)*(side+1)
        var binary=Data()
        func append(_ values:[Float]) -> Int {
            let offset=binary.count
            for value in values { var bits=value.bitPattern.littleEndian;withUnsafeBytes(of:&bits){binary.append(contentsOf:$0)} }
            return offset
        }
        var positions:[Float]=[],uv:[Float]=[],morph:[Float]=[]
        for y in 0...side { for x in 0...side {
            let u=Float(x)/Float(side),v=Float(y)/Float(side)
            positions += [u,v,0];uv += [u,v];morph += [0,0,0.05*sin(u * .pi)*sin(v * .pi)]
        }}
        let p=append(positions),n=append(Array(repeating:[Float](arrayLiteral:0,0,1),count:count).flatMap{$0})
        let t=append(uv),m=append(morph),indices=binary.count
        for y in 0..<side { for x in 0..<side {
            let a=y*(side+1)+x
            for value in [a,a+1,a+side+1,a+1,a+side+2,a+side+1] {
                var value=UInt32(value).littleEndian;withUnsafeBytes(of:&value){binary.append(contentsOf:$0)}
            }
        }}
        let times=append([0,1]),values=append([0,1])
        let metadata:[String:Any]=["v":1,"vertices":count,"triangles":side*side*2,
            "nodes":[["parent":-1,"p":[0,0,0],"q":[0,0,0,1],"s":[1,1,1],"weights":[0]]],
            "meshes":[["node":0,"material":0,"count":count,"position":p,"normal":n,"uv":t,
                       "morphs":[m],"indices":indices,"indexCount":side*side*6]],
            "materials":[["color":[1,1,1],"texture":-1,"doubleSided":true]],"textures":[],
            "clips":[["name":"idle","duration":1,"tracks":[["node":0,"path":3,"size":1,"count":2,
                       "times":times,"values":values,"step":false]]]]]
        var json=try JSONSerialization.data(withJSONObject:metadata,options:.sortedKeys)
        while json.count%4 != 0 {json.append(32)}
        var pack=Data("D3M1".utf8)
        for size in [1,json.count,binary.count] {var value=UInt32(size).littleEndian;withUnsafeBytes(of:&value){pack.append(contentsOf:$0)}}
        pack.append(json);pack.append(binary)
        let optimized=try Model3DOptimizer.optimize(pack)
        XCTAssertLessThan(optimized.triangles,side*side)
        XCTAssertLessThan(optimized.vertices,count)
        func u32(_ data:Data,_ at:Int)->UInt32 {data.withUnsafeBytes{UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:at,as:UInt32.self))}}
        let size=Int(u32(optimized.pack,8))
        let doc=try XCTUnwrap(JSONSerialization.jsonObject(with:optimized.pack.subdata(in:16..<16+size)) as? [String:Any])
        let mesh=try XCTUnwrap((doc["meshes"] as? [[String:Any]])?.first)
        let data=optimized.pack.subdata(in:16+size..<optimized.pack.count)
        func float(_ offset:Int)->Float {Float(bitPattern:u32(data,offset))}
        let position=try XCTUnwrap(mesh["position"] as? Int),texcoord=try XCTUnwrap(mesh["uv"] as? Int)
        let delta=try XCTUnwrap((mesh["morphs"] as? [Int])?.first)
        var border=Set<Int>()
        for i in 0..<optimized.vertices {
            let x=float(position+i*12),y=float(position+i*12+4)
            let ix=Int((x*Float(side)).rounded()),iy=Int((y*Float(side)).rounded()),original=iy*(side+1)+ix
            XCTAssertEqual(float(texcoord+i*8),uv[original*2]);XCTAssertEqual(float(texcoord+i*8+4),uv[original*2+1])
            XCTAssertEqual(float(delta+i*12+8),morph[original*3+2])
            if ix==0||ix==side||iy==0||iy==side {border.insert(original)}
        }
        XCTAssertEqual(border.count,side*4,"Open boundaries must remain fixed to avoid material seams")
        let clip=try XCTUnwrap((doc["clips"] as? [[String:Any]])?.first)
        let track=try XCTUnwrap((clip["tracks"] as? [[String:Any]])?.first)
        let trackValues=try XCTUnwrap(track["values"] as? Int)
        XCTAssertEqual(float(trackValues),0);XCTAssertEqual(float(trackValues+4),1)
        var invalid=pack
        var bad=UInt32(count+1).littleEndian
        withUnsafeBytes(of:&bad){invalid.replaceSubrange(16+json.count+indices..<20+json.count+indices,with:$0)}
        XCTAssertThrowsError(try Model3DOptimizer.optimize(invalid))
    }
}
