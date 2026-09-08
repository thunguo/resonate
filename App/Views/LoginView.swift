import SwiftUI
import CoreImage.CIFilterBuiltins
import MusicCore

struct LoginView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var mode = 0
    @State private var phone = ""
    @State private var countryCode = "86"
    @State private var code = ""
    @State private var countdown = 0
    @State private var busy = false
    @State private var error: String?
    @State private var qr: QRLogin?
    @State private var qrMessage = "准备二维码…"
    @State private var qrExpired = false
    @State private var pollTask: Task<Void, Never>?
    @State private var countdownTask: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Image(systemName: "music.note.house").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(Palette.accent).padding(.top, 18)
                    VStack(alignment: .leading, spacing: 12) { Text("带上你的音乐。").font(.largeTitle.weight(.medium)); Text("连接网易云音乐，找回喜欢的歌、歌单和专辑。").foregroundStyle(Palette.secondary).lineSpacing(5) }
                    Picker("登录方式", selection: $mode) { Text("验证码").tag(0); Text("扫码登录").tag(1) }.pickerStyle(.segmented)
                    if mode == 0 { smsForm } else { qrForm }
                    if let error { InlineError(message: error) }
                    Text("登录信息将通过 music.thunguo.space 连接网易云音乐。会话凭据保存在设备钥匙串中，不会发送给模型厂商。").font(.footnote).foregroundStyle(Palette.secondary).lineSpacing(5)
                }.padding(24)
            }.cabinetBackground().navigationTitle("网易云音乐").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("稍后") { dismiss() } } }
        }.onChange(of: mode) { _, value in error = nil; if value == 1 { startQR() } else { pollTask?.cancel() } }
            .onChange(of: phase) { _, value in if value == .active && mode == 1 { startQR() } else if value != .active { pollTask?.cancel() } }
            .onDisappear { pollTask?.cancel(); countdownTask?.cancel() }
    }
    private var smsForm: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Text("+").foregroundStyle(Palette.secondary)
                TextField("区号", text: $countryCode).keyboardType(.numberPad).frame(width: 45).accessibilityLabel("国家区号")
                Rectangle().fill(Palette.line).frame(width: 1, height: 22)
                TextField("手机号码", text: $phone).keyboardType(.phonePad).textContentType(.telephoneNumber).accessibilityIdentifier("phoneField")
            }.padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            HStack {
                TextField("短信验证码", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode).accessibilityIdentifier("codeField")
                Button(countdown > 0 ? "\(countdown) 秒" : "获取验证码") { sendCode() }.font(.subheadline).frame(minHeight: 44).disabled(countdown > 0 || busy || phone.filter(\.isNumber).count < 6)
            }.padding(.horizontal, 16).padding(.vertical, 6).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            FilledButton(title: busy ? "正在连接…" : "登录并同步收藏") { login() }.disabled(busy || code.count < 4 || phone.filter(\.isNumber).count < 6)
            Text("网易云如要求额外验证，请先在官方 App 完成验证，或使用扫码登录。").font(.footnote).foregroundStyle(Palette.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var qrForm: some View {
        VStack(spacing: 20) {
            if let qr, let image = qrImage(qr.url.absoluteString) { Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 220, height: 220).padding(16).background(.white, in: RoundedRectangle(cornerRadius: 12)).accessibilityLabel("网易云登录二维码") }
            else { ProgressView().frame(width: 250, height: 250) }
            Text(qrMessage).font(.subheadline).foregroundStyle(Palette.secondary)
            Text("请用另一台设备上的网易云 App 扫码。只有这一台 iPhone 时，建议使用验证码登录。").font(.footnote).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
            if qrExpired { Button("刷新二维码") { qr = nil; startQR() }.frame(minHeight: 44) }
        }.frame(maxWidth: .infinity)
    }
    private func sendCode() {
        busy = true; error = nil
        Task { defer { busy = false }; do { try await store.music.sendCode(phone: phone.filter(\.isNumber), countryCode: countryCode); countdown = 60; countdownTask = Task { while countdown > 0 { do { try await Task.sleep(for: .seconds(1)); countdown -= 1 } catch { return } } } } catch { self.error = error.localizedDescription } }
    }
    private func login() {
        busy = true; error = nil
        Task { defer { busy = false }; do { let result = try await store.music.login(phone: phone.filter(\.isNumber), code: code, countryCode: countryCode); try await store.acceptLogin(result); dismiss() } catch { self.error = error.localizedDescription } }
    }
    private func startQR() {
        pollTask?.cancel(); qrExpired = false; error = nil
        pollTask = Task {
            do {
                if qr == nil { qr = try await store.music.createQR() }
                guard let qr else { return }
                for _ in 0..<150 {
                    try Task.checkCancellation()
                    switch try await store.music.checkQR(qr.key) {
                    case .waiting: qrMessage = "等待扫码"
                    case .confirmation: qrMessage = "已扫码，请在网易云 App 中确认"
                    case .expired: qrMessage = "二维码已过期"; qrExpired = true; return
                    case .success(let cookie): qrMessage = "正在同步收藏…"; try await store.acceptQR(cookie: cookie); dismiss(); return
                    }
                    try await Task.sleep(for: .seconds(2))
                }
                qrMessage = "二维码已过期"; qrExpired = true
            } catch is CancellationError { } catch { self.error = error.localizedDescription; qrExpired = true }
        }
    }
    private func qrImage(_ string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(string.utf8)
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 10, y: 10)), let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
