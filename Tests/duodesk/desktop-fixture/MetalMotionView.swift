// GPU-rendered moving desktop content, independent of AppKit's layer update cadence.
import MetalKit

final class MetalMotionView: MTKView, MTKViewDelegate, CAMetalDisplayLinkDelegate {
    // Rendering is decorative. The fixture's parent owns the click marker and keyboard
    // recorder, including acceptsFirstMouse; the Metal subview must not intercept that input.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private let commands: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var frameIndex: UInt32 = 0
    private let began = ProcessInfo.processInfo.systemUptime
    private var displayClock: CAMetalDisplayLink?
    private var lastTarget: CFTimeInterval?
    private var targetIntervalMs: Double = 0
    private let usesMetalClock = ProcessInfo.processInfo.environment["DUODESK_FIXTURE_METAL_LINK"] == "1"
    private let requestedFPS = min(240, max(30, Int(ProcessInfo.processInfo.environment["DUODESK_FIXTURE_FPS"] ?? "120") ?? 120))
    private let usesFrameCode = ProcessInfo.processInfo.environment["DUODESK_FIXTURE_FRAME_CODE"] == "1"
    private let presentations = PresentationAudit()

    init(motionFrame frame: CGRect) throws {
        guard let gpu = MTLCreateSystemDefaultDevice(), let commands = gpu.makeCommandQueue() else {
            throw NSError(domain: "DUOFixtureMetal", code: 1)
        }
        self.commands = commands
        let library = try gpu.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 triangle(uint id [[vertex_id]]) {
            float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
            return float4(p[id],0,1);
        }
        fragment float4 picture(float4 p [[position]], constant float4 &u [[buffer(0)]]) {
            if (u.w > 0.5) {
                uint frame = uint(u.x) & 0xFFFFFFu;
                uint column = min(35u, uint(p.x / u.y * 36.0));
                uint checksum = (frame ^ (frame >> 8) ^ (frame >> 16) ^ 0xA5u) & 255u;
                uint bit;
                if (column < 4) bit = (0xAu >> (3 - column)) & 1u;
                else if (column < 28) bit = (frame >> (27 - column)) & 1u;
                else bit = (checksum >> (35 - column)) & 1u;
                float grey = bit ? 0.85 : 0.15;
                return float4(grey, grey, grey, 1);
            }
            float x = fmod(u.x, 240.0) / 240.0 * u.y;
            if (abs(p.x-x)<16.0) return float4(0.2,0.68,0.9,1);
            return float4(0.05,0.12,0.22,1);
        }
        """, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "triangle")
        descriptor.fragmentFunction = library.makeFunction(name: "picture")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try gpu.makeRenderPipelineState(descriptor: descriptor)
        super.init(frame: frame, device: gpu)
        colorPixelFormat = .bgra8Unorm
        preferredFramesPerSecond = requestedFPS
        if ProcessInfo.processInfo.environment["DUODESK_FIXTURE_UNSYNCED"] == "1", let surface = layer as? CAMetalLayer {
            surface.displaySyncEnabled = false
            print("Fixture diagnostic: Metal display synchronization disabled")
        }
        delegate = self
        if usesMetalClock { isPaused = true }
        print("Fixture uses Metal GPU rendering")
    }
    required init(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard usesMetalClock, let surface = layer as? CAMetalLayer else { return }
        if window == nil {
            displayClock?.invalidate(); displayClock = nil
        } else if displayClock == nil {
            let clock = CAMetalDisplayLink(metalLayer: surface)
            let rate = Float(requestedFPS)
            clock.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
            clock.preferredFrameLatency = 2
            clock.delegate = self
            clock.add(to: .main, forMode: .common)
            displayClock = clock
            print("Fixture uses CAMetalDisplayLink at requested \(requestedFPS) FPS")
        }
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let drawable = currentDrawable, let pass = currentRenderPassDescriptor else { return }
        render(drawable: drawable, pass: pass)
    }
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        if let lastTarget { targetIntervalMs = (update.targetPresentationTimestamp - lastTarget) * 1000 }
        lastTarget = update.targetPresentationTimestamp
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = update.drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        render(drawable: update.drawable, pass: pass)
    }
    private func render(drawable: any CAMetalDrawable, pass: MTLRenderPassDescriptor) {
        guard let command = commands.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        frameIndex &+= 1
        var uniforms = SIMD4<Float>(Float(frameIndex & 0xFFFFFF), Float(drawable.texture.width), Float(drawable.texture.height), usesFrameCode ? 1 : 0)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        drawable.addPresentedHandler { [presentations] drawable in presentations.presented(drawable) }
        // CAMetalDisplayLink supplies the presentation schedule; present(atTime:) is invalid.
        command.present(drawable)
        command.commit()
        if frameIndex % 120 == 0 { print("Fixture Metal frames=\(frameIndex), elapsed=\(ProcessInfo.processInfo.systemUptime - began), targetIntervalMs=\(targetIntervalMs)") }
    }
}
