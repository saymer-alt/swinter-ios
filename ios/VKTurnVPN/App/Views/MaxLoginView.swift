import SwiftUI

struct MaxLoginView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var vm = MaxLoginViewModel()

    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.04, green: 0.05, blue: 0.1)
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        // Header
                        VStack(spacing: 8) {
                            Image(systemName: "envelope.badge.shield.half.filled.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [Color(red: 0.0, green: 0.83, blue: 0.9), Color(red: 0.4, green: 0.5, blue: 1.0)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            Text("Вход в MAX")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.white)
                            Text("Для получения TURN-серверов")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .padding(.top, 20)

                        // Steps
                        if vm.needs2FA {
                            passwordStep
                        } else if !vm.codeSent {
                            phoneStep
                        } else {
                            codeStep
                        }

                        // Error
                        if !vm.errorText.isEmpty {
                            Text(vm.errorText)
                                .font(.system(size: 13))
                                .foregroundStyle(.red.opacity(0.9))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
            }
            .navigationTitle("MAX Авторизация")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") { dismiss() }
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .onChange(of: vm.loginDone) { done in
                if done { dismiss() }
            }
        }
    }

    // MARK: - Phone Step

    private var phoneStep: some View {
        GlassSection(title: "НОМЕР ТЕЛЕФОНА", icon: "phone.fill") {
            HStack(spacing: 8) {
                Text("+")
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))

                TextField("", text: $vm.phone, prompt: Text("79001234567").foregroundColor(.white.opacity(0.2)))
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .keyboardType(.phonePad)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.white.opacity(0.06), lineWidth: 0.5)
            )

            Button {
                Task { await vm.requestCode() }
            } label: {
                HStack(spacing: 8) {
                    if vm.isLoading {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.8)
                    }
                    Text(vm.isLoading ? "Отправляем..." : "Отправить код")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            vm.phone.count >= 10
                                ? LinearGradient(colors: [Color(red: 0.0, green: 0.7, blue: 0.8), Color(red: 0.3, green: 0.4, blue: 0.9)], startPoint: .leading, endPoint: .trailing)
                                : LinearGradient(colors: [.gray.opacity(0.3), .gray.opacity(0.3)], startPoint: .leading, endPoint: .trailing)
                        )
                )
            }
            .disabled(vm.phone.count < 10 || vm.isLoading)

            Text("SMS-код придёт на указанный номер")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.3))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }

    // MARK: - Code Step

    private var codeStep: some View {
        GlassSection(title: "SMS-КОД", icon: "lock.fill") {
            // Show phone
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green.opacity(0.7))
                    .font(.system(size: 14))
                Text("Код отправлен на +\(vm.phone)")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
            }

            // Code input
            TextField("", text: $vm.code, prompt: Text("Введите код").foregroundColor(.white.opacity(0.2)))
                .font(.system(size: 24, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .frame(height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(0.06), lineWidth: 0.5)
                )

            Button {
                Task { await vm.confirmAndLogin() }
            } label: {
                HStack(spacing: 8) {
                    if vm.isLoading {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.8)
                    }
                    Text(vm.isLoading ? "Входим..." : "Войти")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            vm.code.count >= 4
                                ? LinearGradient(colors: [Color(red: 0.0, green: 0.7, blue: 0.8), Color(red: 0.3, green: 0.4, blue: 0.9)], startPoint: .leading, endPoint: .trailing)
                                : LinearGradient(colors: [.gray.opacity(0.3), .gray.opacity(0.3)], startPoint: .leading, endPoint: .trailing)
                        )
                )
            }
            .disabled(vm.code.count < 4 || vm.isLoading)

            // Resend / change number
            HStack {
                Button("Другой номер") {
                    vm.reset()
                }
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.4))

                Spacer()

                if vm.resendTimer > 0 {
                    Text("Повтор через \(vm.resendTimer)с")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.3))
                } else {
                    Button("Отправить снова") {
                        Task { await vm.requestCode() }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 0.0, green: 0.83, blue: 0.9))
                }
            }
        }
    }

    // MARK: - 2FA Password Step

    private var passwordStep: some View {
        GlassSection(title: "ДВУХФАКТОРНАЯ АВТОРИЗАЦИЯ", icon: "lock.shield.fill") {
            // Info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange.opacity(0.8))
                        .font(.system(size: 14))
                    Text("Требуется пароль")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                if !vm.twoFAEmail.isEmpty {
                    Text("Email: \(vm.twoFAEmail)")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                }
                if !vm.twoFAHint.isEmpty {
                    Text("Подсказка: \(vm.twoFAHint)")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }

            // Password input
            SecureField("", text: $vm.password, prompt: Text("Введите пароль").foregroundColor(.white.opacity(0.2)))
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.9))
                .autocorrectionDisabled()
                .textContentType(.password)
                .padding(.horizontal, 12)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(0.06), lineWidth: 0.5)
                )

            Button {
                Task { await vm.submit2FA() }
            } label: {
                HStack(spacing: 8) {
                    if vm.isLoading {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.8)
                    }
                    Text(vm.isLoading ? "Проверяем..." : "Подтвердить")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            !vm.password.isEmpty
                                ? LinearGradient(colors: [Color(red: 0.0, green: 0.7, blue: 0.8), Color(red: 0.3, green: 0.4, blue: 0.9)], startPoint: .leading, endPoint: .trailing)
                                : LinearGradient(colors: [.gray.opacity(0.3), .gray.opacity(0.3)], startPoint: .leading, endPoint: .trailing)
                        )
                )
            }
            .disabled(vm.password.isEmpty || vm.isLoading)

            Button("Начать заново") {
                vm.reset()
            }
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.4))
        }
    }

}

// MARK: - ViewModel

@MainActor
class MaxLoginViewModel: ObservableObject {
    @Published var phone = ""
    @Published var code = ""
    @Published var password = ""
    @Published var codeSent = false
    @Published var needs2FA = false
    @Published var isLoading = false
    @Published var errorText = ""
    @Published var loginDone = false
    @Published var resendTimer = 0
    @Published var twoFAEmail = ""
    @Published var twoFAHint = ""

    private var verifyToken = ""
    private var trackId = ""
    private var timerTask: Task<Void, Never>?
    private let auth = MaxAuthService.shared

    private var cleanFullPhone: String {
        let clean = phone
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        return clean.hasPrefix("+") ? clean : "+\(clean)"
    }

    func requestCode() async {
        isLoading = true
        errorText = ""

        do {
            let result = try await auth.requestCode(phone: cleanFullPhone)
            verifyToken = result.verifyToken
            codeSent = true
            startResendTimer()
        } catch {
            errorText = error.localizedDescription
        }

        isLoading = false
    }

    func confirmAndLogin() async {
        isLoading = true
        errorText = ""

        do {
            let result = try await auth.fullLogin(phone: cleanFullPhone, code: code, verifyToken: verifyToken)
            switch result {
            case .token:
                loginDone = true
            case .passwordChallenge(let tid, let email, let hint):
                trackId = tid
                twoFAEmail = email
                twoFAHint = hint
                needs2FA = true
            }
        } catch {
            errorText = error.localizedDescription
        }

        isLoading = false
    }

    func submit2FA() async {
        isLoading = true
        errorText = ""

        do {
            try await auth.fullLoginWith2FA(phone: cleanFullPhone, trackId: trackId, password: password)
            loginDone = true
        } catch {
            errorText = error.localizedDescription
        }

        isLoading = false
    }

    func reset() {
        codeSent = false
        needs2FA = false
        code = ""
        password = ""
        verifyToken = ""
        trackId = ""
        twoFAEmail = ""
        twoFAHint = ""
        errorText = ""
        timerTask?.cancel()
        resendTimer = 0
    }

    private func startResendTimer() {
        resendTimer = 60
        timerTask?.cancel()
        timerTask = Task {
            while resendTimer > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                resendTimer -= 1
            }
        }
    }
}
