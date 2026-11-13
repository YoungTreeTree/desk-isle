import Foundation

extension WidgetRegistry {
    static let model3D = WidgetDefinition(
        kind:.model3D,wireID:Component.model3DID,title:"3D 模型",symbol:"cube.transparent",
        settingsTitle:"3D 模型",settingsSymbol:"cube.transparent",summary:"透明背景 · 板端绘制 · 运行时上传",addTitle:"添加 3D 模型…",
        defaults:[ComponentSizePreset(GridSize(columns:8,rows:12))],
        accepted:[ComponentSizePreset(GridSize(columns:8,rows:12)),ComponentSizePreset(GridSize(columns:32,rows:18)),ComponentSizePreset(GridSize(columns:18,rows:32))],
        selectable:[ComponentSizePreset(GridSize(columns:8,rows:12))],placement:.firstFree,minimumWidgetVersion:3)
}

struct Model3DStats: Equatable, Sendable {
    let width,height: Int
    let frames,presented: UInt64
    let elapsed,renderTime,maxTime,averageTime: Double
    let triangles,vertices,packBytes,rendererBytes,freePSRAM,largestPSRAM,freeInternal: Int
    var fps: Double { elapsed > 0 ? Double(presented) / elapsed : 0 }
    var renderOccupancy: Double { elapsed > 0 ? min(100,renderTime/elapsed*100) : 0 }
    init?(line: String, sequence: UInt32) {
        let f=line.split(separator:" ")
        guard f.count == 18,f[0] == "DESKISLE_3D_STATS",f[1] == "1",UInt32(f[2]) == sequence else { return nil }
        let n=f.dropFirst(3).compactMap { UInt64($0) }
        guard n.count == 15,n.allSatisfy({ $0 <= UInt64(Int.max) }) else { return nil }
        width=Int(n[0]);height=Int(n[1]);frames=n[2];presented=n[3]
        elapsed=Double(n[4])/1_000_000;renderTime=Double(n[5])/1_000_000
        maxTime=Double(n[6])/1_000;averageTime=Double(n[7])/1_000
        triangles=Int(n[8]);vertices=Int(n[9]);packBytes=Int(n[10]);rendererBytes=Int(n[11])
        freePSRAM=Int(n[12]);largestPSRAM=Int(n[13]);freeInternal=Int(n[14])
    }
}
