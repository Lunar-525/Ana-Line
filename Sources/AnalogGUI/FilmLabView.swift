import SwiftUI
import AnalogCore
import AnalogImaging
import UniformTypeIdentifiers

struct FilmLabWorkspace: View {
    @ObservedObject var model: PreviewModel
    @ObservedObject var lab: FilmLabController
    @State private var display = FilmLabDisplay.appearance
    @State private var dropTarget = false
    @State private var showReset = false
    private var stage: FilmLabStage { lab.session.stage }
    private var probe: FilmLabState { FilmLabPhysics.replay(lab.session) }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: stage.symbol).font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading,spacing: 2) {
                    Text("\(stage.rawValue+1) / 7 · \(stage.title)").font(.title2.bold())
                    Text(stage == .scan ? "处理完成 · 扫描正像" : "黑白负片 · 虚拟暗房").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("简化反应／扩散模型").font(.caption).foregroundStyle(.secondary)
                Button("新胶片") { showReset = true }.disabled(lab.running)
            }
            HStack(alignment: .top,spacing: 16) {
                VStack(spacing: 10) {
                    Picker("观察",selection: $display) {
                        ForEach(FilmLabDisplay.allCases,id: \.rawValue) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    ZStack(alignment: .bottomLeading) {
                        Color.black.opacity(0.45)
                        if let image = model.processed {
                            Image(nsImage: image).resizable().scaledToFit().padding(12)
                        } else { Text("载入照片开始曝光").foregroundStyle(.secondary) }
                        Text(display == .appearance ? (stage == .scan ? "扫描正像" : "透射负片 · 潜影在显影前不可见") : "\(display.title) · 黑 0 → 白 1")
                            .font(.caption2).padding(7).background(.black.opacity(0.7)).padding(10)
                    }.frame(minHeight: 220,maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 10).stroke(.orange,lineWidth: 3) } }
                        .onDrop(of: [UTType.fileURL,UTType.image],isTargeted: $dropTarget) { providers in model.dropImages(providers); return true }
                        .contextMenu { Button("粘贴图片") { model.pasteImage() } }
                    FilmLabSceneView(lab: lab,probe: probe).frame(height: 218)
                }
                ScrollView { controls.padding(.trailing,5) }.frame(width: 285)
            }.frame(minHeight: 430)
            HStack {
                Button { lab.undo() } label: { Label("撤销到上一步",systemImage: "arrow.uturn.backward") }
                    .disabled(!lab.session.canUndo)
                Spacer()
                if stage != .scan {
                    Text(String(format: "已处理 %.1f 秒",lab.session.elapsed)).font(.caption.monospacedDigit())
                    Picker("速度",selection: $lab.speed) { Text("1×").tag(Float(1)); Text("10×").tag(Float(10)); Text("60×").tag(Float(60)) }.frame(width: 100).disabled(stage == .exposure)
                    Button(lab.running ? "暂停" : "开始") { lab.toggle() }
                    Button(stage == .exposure ? "−1 秒" : "−30 秒") { lab.rewind(stage == .exposure ? 1 : 30) }
                        .disabled(lab.session.elapsed == 0)
                        .help("暂停并回退当前阶段，恢复该时刻的条件与胶片状态")
                    Button(stage == .exposure ? "+1 秒" : "+30 秒") { lab.advance(stage == .exposure ? 1 : 30) }.disabled(lab.running)
                    Button("完成 → 下一步") { lab.complete(); display = .appearance }.buttonStyle(.borderedProminent)
                        .disabled(!lab.session.canAdvance)
                } else {
                    Button("导出扫描图像…") { model.exportFilmLab() }.buttonStyle(.borderedProminent)
                }
            }
            if let error = lab.persistenceError { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .disabled(model.busy || model.original == nil)
        .onAppear { sync() }
        .onChange(of: lab.session) { _ in sync() }
        .onChange(of: display) { _ in sync() }
        .onChange(of: model.selected) { lab.scannerPreset = $0 }
        .onChange(of: model.settings.lutMix) { lab.scannerMix = $0 }
        .onDisappear { lab.pause() }
        .confirmationDialog("重新开始将清除当前胶片的冲洗记录。",isPresented: $showReset) {
            Button("重新开始",role: .destructive) { lab.reset(); display = .appearance }
        }
    }
    private func sync() {
        if model.selected != lab.scannerPreset { model.selected = lab.scannerPreset }
        var settings = model.settings
        settings.lutMix = lab.scannerMix
        settings.laboratory = lab.session; settings.laboratoryDisplay = display.rawValue
        model.settings = settings
    }
    @ViewBuilder private var controls: some View {
        VStack(alignment: .leading,spacing: 14) {
            Text(stage.title+"控制").font(.headline)
            Text(instruction).font(.caption).foregroundStyle(.secondary)
            switch stage {
            case .exposure:
                slider("曝光补偿 · EV",\.exposureEV,-6...6,0)
                slider("光源色温 · K",\.kelvin,2000...12000,5500)
                HStack { Button("钨丝灯") { lab.session.recipe.kelvin = 2850 }; Button("日光") { lab.session.recipe.kelvin = 5500 }; Button("阴天") { lab.session.recipe.kelvin = 7000 } }.controlSize(.small)
                slider("边缘漏光",\.lightLeak,0...1,0)
                Text("三波段光谱近似 · RGB 输入无法恢复完整光谱；色温改变潜影曝光密度。").font(.caption2).foregroundStyle(.secondary)
            case .development:
                Picker("显影液",selection: $lab.session.recipe.developer) {
                    ForEach(FilmDeveloper.allCases,id: \.self) { Text($0.rawValue).tag($0) }
                }.onChange(of: lab.session.recipe.developer) { developer in lab.session.recipe.dilution = developer.dilutions[0] }
                Text(lab.session.recipe.developer.description).font(.caption).foregroundStyle(.secondary)
                Picker("稀释",selection: $lab.session.recipe.dilution) {
                    ForEach(lab.session.recipe.developer.dilutions,id: \.self) { Text($0 == 0 ? "原液" : "1+\($0)").tag($0) }
                }
                bathControls
                Link("厂商技术资料",destination: URL(string: lab.session.recipe.developer.sourceURL)!).font(.caption)
                Text("药液特性参考厂商；反应系数为模型估计。当前为通用全色乳剂，时间不代表特定胶片的推荐配方。").font(.caption2).foregroundStyle(.secondary)
            case .stop, .fixation:
                bathControls
            case .wash:
                slider("水温 · °C",\.temperature,10...45,20)
                slider("换水／水流",\.flow,0...1,0.6)
                Text("残留物通过乳剂深度扩散并随清水交换移除。水洗不足的残留会进入干燥阶段。").font(.caption)
            case .drying:
                slider("空气温度 · °C",\.temperature,10...45,20)
                slider("相对湿度",\.humidity,0...0.99,0.45)
                slider("气流",\.airflow,0...1,0.5)
                slider("水中矿物质",\.minerals,0...1,0.05)
                slider("环境灰尘",\.dust,0...1,0.02)
            case .scan:
                ParameterSlider(name: "扫描曝光 · EV",value: $lab.session.scanEV,defaultValue: 0,range: -4...4)
                ParameterSlider(name: "扫描反差",value: $lab.session.scanContrast,defaultValue: 1,range: 0.5...2)
                ParameterSlider(name: "扫描 LUT 混合",value: $model.settings.lutMix,defaultValue: 1,range: 0...1,percent: true)
                Text("上方选择扫描色调 LUT。导出使用原图分辨率、同一份操作记录与固定种子。").font(.caption)
            }
            Divider()
            Text("中途调整只影响接下来的处理。点击“完成”保留当前结果，即使处理不足也能继续。").font(.caption2).foregroundStyle(.secondary)
            if stage != .exposure && stage != .scan {
                Text("参考时长：\(Int(stage.defaultDuration)) 秒（模型尺度）").font(.caption)
                ProgressView(value: min(Double(lab.session.elapsed/stage.defaultDuration),1))
                Text("未模拟长期保存老化；化学残留视图用于观察当前风险来源。").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private var instruction: String {
        switch stage {
        case .exposure: "光照在乳剂中形成潜影。先设定光源，再开始曝光。"
        case .development: "显影剂从表面进入乳剂，将有潜影的卤化银还原为金属银。"
        case .stop: "停显液进入乳剂，逐步中和残余显影剂。"
        case .fixation: "定影液移除未显影的卤化银，已形成的金属银保留。"
        case .wash: "让乳剂中的残余药液向清水扩散。"
        case .drying: "水膜蒸发，矿物质与化学残留沉积，湿表面可能附着灰尘。"
        case .scan: "透射负片转换为正像，完成最终输出。"
        }
    }
    private var bathControls: some View {
        VStack(spacing: 12) {
            slider("药液温度 · °C",\.temperature,10...45,20)
            slider("药液浓度",\.strength,0...2,1)
            if stage != .stop { slider("药液新鲜度",\.freshness,0...1,1) }
            slider("搅动强度",\.agitation,0...1,0.6)
        }
    }
    private func slider(_ name: String,_ key: WritableKeyPath<FilmLabRecipe,Float>,_ range: ClosedRange<Float>,_ value: Float) -> some View {
        ParameterSlider(name: name,value: Binding(get: { lab.session.recipe[keyPath: key] },set: { lab.session.recipe[keyPath: key] = $0 }),defaultValue: value,range: range)
    }
}

