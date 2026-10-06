import SwiftUI
import PhotosUI

/// Step hub: the user can do the steps in any order; the more steps done, the more of the report is verified.
struct InspectionFlowView: View {
    init(session: InspectionSession, onClose: @escaping () -> Void) { self.session = session; self.onClose = onClose }
    @Bindable var session: InspectionSession
    var onClose: () -> Void
    @State private var analyzing = false
    @State private var progress = 0.0
    @State private var status = ""
    @State private var result: InspectionReport?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    step("Vehicle details & VIN", "car.fill", done: !session.vehicle.make.isEmpty) { VehicleStepView(session: session) }
                    step("AR paint scan + gauge", "arkit", done: !session.exteriorPhotos.isEmpty || !session.livePaint.isEmpty,
                         detail: exteriorDetail) { LivePaintScanView(session: session) }
                    step("Glass stamps (screens & windows)", "rectangle.split.3x1", done: !session.glassPhotos.isEmpty) { GlassStepView(session: session) }
                    step("Tyres (DOT age + tread)", "circle.circle", done: !session.tyreSidewallPhotos.isEmpty || !session.tyreTreadPhotos.isEmpty) { TyreStepView(session: session) }
                    step("Interior & dashboard", "steeringwheel", done: !session.interiorPhotos.isEmpty) { InteriorStepView(session: session) }
                } header: { Text("Scan") }

                Section {
                    step("Engine sound", "waveform", done: !session.engineSamples.isEmpty) { EngineSoundView(session: session) }
                    step("OBD-II fault codes (optional)", "cable.connector", done: session.obd?.connected == true) { OBDStepView(session: session) }
                    step("Suspension bounce test", "arrow.up.and.down.circle", done: !session.suspension.isEmpty) { SuspensionStepView(session: session) }
                    step("Paint gauge readings (list)", "ruler", done: !session.gaugeReadings.isEmpty) { GaugeStepView(session: session) }
                    step("Inspector checklist", "checklist", done: !session.checklist.isEmpty) { ChecklistView(session: session) }
                } header: { Text("Verify") } footer: {
                    Text("Scans are analysed on-device. A paint gauge turns a camera \"check\" into a confirmed finding; without it, the report never calls a car an accident car from colour alone.")
                }

                Section {
                    Button {
                        Task { await analyze() }
                    } label: {
                        Label("Generate report", systemImage: "doc.text.magnifyingglass").font(.headline)
                    }
                    .disabled(session.completedSteps < 2 || analyzing)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("New inspection")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose) } }
            .overlay { if analyzing { AnalyzingOverlay(progress: progress, status: status) } }
            .navigationDestination(item: $result) { ReportView(report: $0) }
        }
    }

    private var exteriorDetail: String? {
        let names = session.livePaint.filter(\.value.mismatched).keys.map(\.displayName).sorted()
        if !names.isEmpty { return "Check with gauge: " + names.prefix(2).joined(separator: ", ") }
        if !session.livePaint.isEmpty || !session.exteriorPhotos.isEmpty { return "Paint checked" }
        return nil
    }

    private func step<D: View>(_ title: String, _ icon: String, done: Bool, detail: String? = nil, @ViewBuilder dest: () -> D) -> some View {
        NavigationLink(destination: dest()) {
            HStack {
                Image(systemName: icon).frame(width: 28).foregroundStyle(Theme.accent)
                VStack(alignment: .leading) {
                    Text(title)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? Theme.accent : .secondary)
            }
        }
        .listRowBackground(Theme.card)
    }

    @MainActor private func analyze() async {
        analyzing = true
        // `run` is a nonisolated async function, so the heavy work executes off the main actor.
        let report = await InspectionAnalyzer().run(session) { p, msg in progress = p; status = msg }
        ReportStore.shared.save(report)
        analyzing = false
        result = report
    }
}

struct AnalyzingOverlay: View {
    let progress: Double
    let status: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 18) {
                ProgressView(value: progress).tint(Theme.accent).frame(width: 220)
                Text(status).font(.subheadline).foregroundStyle(.white)
                Text("Running AI models on-device…").font(.caption).foregroundStyle(.secondary)
            }
            .padding(28).background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}

// MARK: - Vehicle

struct VehicleStepView: View {
    init(session: InspectionSession) { self.session = session }
    @Bindable var session: InspectionSession
    @State private var vinPhoto: PhotosPickerItem?
    @State private var showCamera = false

    var body: some View {
        Form {
            Section("Condition") {
                Picker("Car is", selection: $session.vehicle.condition) {
                    ForEach(VehicleCondition.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
            }
            Section("Vehicle") {
                TextField("Make (e.g. Toyota)", text: $session.vehicle.make)
                TextField("Model (e.g. Corolla)", text: $session.vehicle.model)
                Stepper("Year: \(String(session.vehicle.year))", value: $session.vehicle.year, in: 1980...2030)
                TextField("Mileage (km)", value: $session.vehicle.mileageKm, format: .number).keyboardType(.numberPad)
                Stepper("Cylinders: \(session.vehicle.cylinders)", value: $session.vehicle.cylinders, in: 2...12)
            }
            Section {
                TextField("VIN or chassis no. (e.g. NZE141-1234567)", text: $session.vehicle.vin).textInputAutocapitalization(.characters)
                Button { showCamera = true } label: { Label("Scan VIN / chassis no. with camera", systemImage: "text.viewfinder") }
                if let y = TextScanner.modelYear(fromVIN: session.vehicle.vin) {
                    Text("VIN model year: \(String(y))").font(.caption).foregroundStyle(y == session.vehicle.year ? Theme.accent : Theme.warn)
                }
            } header: { Text("VIN") } footer: {
                Text("The VIN year is used to check whether glass, tyres and parts are original.")
            }
        }
        .scrollContentBackground(.hidden).background(Theme.bg)
        .navigationTitle("Vehicle")
        .sheet(isPresented: $showCamera) {
            SingleShotCamera(title: "Frame the VIN plate / windscreen VIN") { img in
                if let v = TextScanner.findVehicleID(in: TextScanner.recognize(img)) { session.vehicle.vin = v }
            }
        }
    }
}

// MARK: - Glass

struct GlassStepView: View {
    init(session: InspectionSession) { self.session = session }
    @Bindable var session: InspectionSession
    @State private var target: CarPart?
    let parts: [CarPart] = [.windshield, .rearWindow, .frontLeftWindow, .frontRightWindow, .rearLeftWindow, .rearRightWindow]

    var body: some View {
        List {
            Section {
                Text("Photograph the small printed stamp (brand logo, codes and dots) in the corner of each glass. A windscreen from a different brand or year than the rest means it was replaced — often after an accident.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(parts) { p in
                Button { target = p } label: {
                    HStack {
                        Text(p.displayName).foregroundStyle(.white)
                        Spacer()
                        if let img = session.glassPhotos[p] {
                            Image(uiImage: img).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                        } else { Image(systemName: "camera").foregroundStyle(Theme.accent) }
                    }
                }
                .listRowBackground(Theme.card)
            }
        }
        .scrollContentBackground(.hidden).background(Theme.bg)
        .navigationTitle("Glass stamps")
        .sheet(item: $target) { p in
            SingleShotCamera(title: "\(p.displayName): fill the frame with the stamp") { session.glassPhotos[p] = $0 }
        }
    }
}

// MARK: - Tyres

struct TyreStepView: View {
    init(session: InspectionSession) { self.session = session }
    @Bindable var session: InspectionSession
    @State private var shot: (CarPart, Bool)?   // (position, isSidewall)
    @State private var showing = false
    let positions: [CarPart] = [.wheelFrontLeft, .wheelFrontRight, .wheelRearLeft, .wheelRearRight]

    var body: some View {
        List {
            Section {
                Text("Sidewall: photograph the DOT code (last 4 digits = week & year made). Tread: photograph the tread surface straight on. Enter a tread-depth reading if you have a gauge (a coin test is fine).")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(positions) { p in
                Section(p.displayName) {
                    Button { shot = (p, true); showing = true } label: {
                        row("Sidewall DOT code", done: session.tyreSidewallPhotos[p] != nil)
                    }
                    Button { shot = (p, false); showing = true } label: {
                        row("Tread photo", done: session.tyreTreadPhotos[p] != nil)
                    }
                    HStack {
                        Text("Tread depth (mm)")
                        Spacer()
                        TextField("e.g. 6.5", value: Binding(get: { session.treadDepthMM[p] }, set: { session.treadDepthMM[p] = $0 }), format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80)
                    }
                }
                .listRowBackground(Theme.card)
            }
        }
        .scrollContentBackground(.hidden).background(Theme.bg)
        .navigationTitle("Tyres")
        .sheet(isPresented: $showing) {
            if let s = shot {
                SingleShotCamera(title: s.1 ? "\(s.0.displayName): DOT code" : "\(s.0.displayName): tread") { img in
                    if s.1 { session.tyreSidewallPhotos[s.0] = img } else { session.tyreTreadPhotos[s.0] = img }
                }
            }
        }
    }

    private func row(_ t: String, done: Bool) -> some View {
        HStack { Text(t).foregroundStyle(.white); Spacer(); Image(systemName: done ? "checkmark.circle.fill" : "camera").foregroundStyle(Theme.accent) }
    }
}

// MARK: - Interior

struct InteriorStepView: View {
    init(session: InspectionSession) { self.session = session }
    @Bindable var session: InspectionSession
    @State private var picks: [PhotosPickerItem] = []
    @State private var cam = false
    @State private var dashCam = false

    var body: some View {
        List {
            Section {
                Text("Take photos of: driver seat, rear seats, steering wheel, pedals, gear knob, headliner. Then the dashboard with engine running (warning lights + odometer).")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                Button { cam = true } label: { Label("Take interior photo", systemImage: "camera") }
                PhotosPicker(selection: $picks, matching: .images) { Label("Import photos", systemImage: "photo.on.rectangle") }
                Button { dashCam = true } label: {
                    Label(session.dashboardPhoto == nil ? "Dashboard (engine running)" : "Dashboard ✓", systemImage: "gauge.with.dots.needle.33percent")
                }
            }.listRowBackground(Theme.card)
            if !session.interiorPhotos.isEmpty {
                Section("\(session.interiorPhotos.count) photos") { PhotoStrip(images: session.interiorPhotos) }.listRowBackground(Theme.card)
            }
        }
        .scrollContentBackground(.hidden).background(Theme.bg)
        .navigationTitle("Interior")
        .sheet(isPresented: $cam) { SingleShotCamera(title: "Interior", keepOpen: true) { session.interiorPhotos.append($0) } }
        .sheet(isPresented: $dashCam) { SingleShotCamera(title: "Dashboard with engine running") { session.dashboardPhoto = $0 } }
        .onChange(of: picks) { _, items in
            Task {
                for i in items {
                    if let d = try? await i.loadTransferable(type: Data.self), let img = UIImage(data: d) { session.interiorPhotos.append(img) }
                }
                picks = []
            }
        }
    }
}

// MARK: - Gauge & checklist

struct GaugeStepView: View {
    init(session: InspectionSession) { self.session = session }
    @Bindable var session: InspectionSession
    // Magnetic gauges only read paint on steel (or aluminium with an NFe probe), not on plastic bumpers.
    let parts = CarPart.allCases.filter { $0.group == .body && $0.surface != .plastic }
    var body: some View {
        Form {
            Section {
                Text("Factory paint is usually 90–160 µm. Above ~200 µm means a re-spray (shower); above ~400 µm means body filler. Measure the roof first (almost never repainted) as your baseline. Faster: use the AR paint scan and aim the crosshair at each panel.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Readings (µm)") {
                ForEach(parts) { p in
                    HStack {
                        Text(p.displayName)
                        Spacer()
                        TextField("—", value: Binding(get: { session.gaugeReadings[p] }, set: { session.gaugeReadings[p] = $0 }), format: .number)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 80)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden).background(Theme.bg)
        .navigationTitle("Paint gauge")
    }
}

struct ChecklistView: View {
    init(session: InspectionSession) { self.session = session }
    @Bindable var session: InspectionSession
    var body: some View {
        List {
            Section {
                Text("Things a camera can't reliably see. Answer each one — they feed the Structure, Engine and Gearbox scores (marked \"inspector\" in the report).")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(InspectionSession.checklistItems, id: \.self) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item)
                    Picker("", selection: Binding(get: { session.checklist[item].map { $0 ? 1 : 0 } ?? -1 },
                                                  set: { session.checklist[item] = $0 == -1 ? nil : $0 == 1 })) {
                        Text("Not checked").tag(-1); Text("No").tag(0); Text("Yes").tag(1)
                    }.pickerStyle(.segmented)
                }
                .listRowBackground(Theme.card)
            }
        }
        .scrollContentBackground(.hidden).background(Theme.bg)
        .navigationTitle("Checklist")
    }
}

struct PhotoStrip: View {
    let images: [UIImage]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(images.indices, id: \.self) { i in
                    Image(uiImage: images[i]).resizable().scaledToFill().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}

