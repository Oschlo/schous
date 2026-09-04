import SwiftUI

/// Innstillinger som paneler: det daglige først, feilsøking og modellinstruks
/// under Avansert. Vinduet følger panelet i høyde, og macOS setter tittelen
/// etter valgt fane selv.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralPane().tabItem { Label("Generelt", systemImage: "gearshape") }
            TranscriptionPane().tabItem { Label("Transkribering", systemImage: "waveform") }
            SummaryPane().tabItem { Label("Referat", systemImage: "doc.text") }
            AdvancedPane().tabItem { Label("Avansert", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 540)
    }
}

/// Kopierer til utklippstavla og sier «Kopiert» en stund. Ingen `CopyButton`
/// i SwiftUI på macOS 14, og NSPasteboard er fire linjer.
struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Kopiert" : "Kopier", systemImage: copied ? "checkmark" : "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        }
        .controlSize(.small)
        .accessibilityLabel(copied ? "Kopiert" : "Kopier kommandoen")
    }
}

private struct GeneralPane: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Målmappe") {
                LabeledContent("Lagre i") {
                    HStack {
                        Text(URL(fileURLWithPath: settings.outputPath).lastPathComponent)
                            .lineLimit(1).truncationMode(.head)
                            .help(settings.outputPath)
                        Button("Velg…") { settings.pickOutputFolder() }
                    }
                }
                Text("Transkripsjon, referat og menylinje-opptak havner her.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Eksportformater") {
                ForEach(OutputFormat.allCases) { f in
                    Toggle(f.label, isOn: Binding(
                        get: { settings.formats.contains(f) },
                        set: { on in
                            if on { settings.formats.insert(f) } else { settings.formats.remove(f) }
                        }))
                }
                Text("Hva «Eksporter» skriver som standard. Menyen på knappen "
                     + "kan skrive ett enkelt format uten å endre dette.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

}

private struct TranscriptionPane: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Backend") {
                HStack {
                    TextField("Mappe", text: $settings.backendPath,
                              prompt: Text("mac-local-transcribe-with-diarization"))
                        .textFieldStyle(.roundedBorder)
                    Button("Velg…", action: pickBackend)
                }
                // Bare feltet og knappene låses mens en sjekk går — ikke hele
                // skjemaet. Sjekken kjører på stien slik den var da den
                // startet, så et felt som kan endres imens ville gitt et
                // grønt svar på noe som aldri ble sjekket.
                .disabled(settings.checking)
                HStack {
                    Button("Test backend", action: settings.runSelfcheck)
                    Button("Test modelltilgang", action: settings.runAccessCheck)
                    if settings.checking {
                        ProgressView().controlSize(.small)
                        Button("Avbryt") { settings.cancelCheck() }
                    }
                }
                if let r = settings.checkResult {
                    Text(r).font(.caption).textSelection(.enabled)
                        .foregroundStyle(r.hasPrefix("✓") ? .green : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("«Test backend» er lokal: ffmpeg, torch, pyannote, mlx-whisper. "
                     + "«Test modelltilgang» spør Hugging Face om tokenet lever og om "
                     + "modell-lisensene er godtatt — den eneste sjekken som bruker nett.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Modeller") {
                if AppSettings.modelsCached {
                    Label("Modellene er lastet ned", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Modellene lastes ned ved første kjøring (~3 GB)", systemImage: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                }
                Text("Tokenet til Hugging Face settes i backend-mappen, ikke her — se Avansert.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func pickBackend() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Velg"
        if panel.runModal() == .OK, let url = panel.url {
            settings.backendPath = url.path   // nullstiller checkResult selv
        }
    }
}

private struct SummaryPane: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("ollama") {
                TextField("ollama-URL", text: $settings.ollamaURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await settings.refreshModels() } }
                HStack {
                    if let models = settings.models {
                        Picker("Standardmodell", selection: $settings.summaryModel) {
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                            // Lagret modell som ikke finnes lenger: vis den, så
                            // valget ikke stille byttes til noe annet.
                            if !settings.summaryModel.isEmpty, !models.contains(settings.summaryModel) {
                                Text("\(settings.summaryModel) (ikke installert)").tag(settings.summaryModel)
                            }
                        }
                    } else {
                        Text("ollama svarer ikke på \(settings.ollamaURL)")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button("Hent modeller") { Task { await settings.refreshModels() } }
                }
                Picker("Standardspråk", selection: $settings.summaryLanguage) {
                    ForEach(SummaryLanguage.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Maler") {
                Button("Åpne malmappe") { Templates.open() }
                Text("Én *.md per mal. Filnavnet er malnavnet. Referatet skrives som "
                     + "<fil>.<mal>.md i målmappa.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await settings.refreshModels() }
    }
}

private struct AdvancedPane: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var showPrompt = false

    var body: some View {
        Form {
            Section("Modellinstruks") {
                // Engelsk med vilje: modellene følger engelske instrukser mest
                // pålitelig, og språket på referatet styres av {language}. Dette
                // er en instruks til modellen, ikke norsk UI-tekst.
                DisclosureGroup("Prompt (engelsk)", isExpanded: $showPrompt) {
                    TextEditor(text: $settings.summaryPrompt)
                        .font(.caption.monospaced())
                        .frame(minHeight: 160)
                        .accessibilityLabel("Modellinstruks")
                    HStack {
                        Text("{template} {language} {context} {transcript} byttes ut før sending. "
                             + "Det som står her er nøyaktig det som sendes.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Tilbakestill") { settings.summaryPrompt = Summary.defaultPrompt }
                            .disabled(settings.summaryPrompt == Summary.defaultPrompt)
                    }
                }
            }
            Section("Hugging Face") {
                // Ikke et felt: tokenet eies av huggingface_hub, som leser
                // HF_TOKEN og faller tilbake på ~/.cache/huggingface/token.
                // En egen kopi her måtte ligge i Keychain, og den ACL-en er
                // nøklet på cdhash — altså én dialog per build. Se #26.
                Text("Tokenet settes i backend-mappen, ikke her. Appen ignorerer "
                     + "`HF_TOKEN` i miljøet med vilje, så en `export` i "
                     + "`~/.zshenv` gjelder terminalen og ikke appen. "
                     + "«Test modelltilgang» sier fra hvis det mangler.")
                    .font(.caption).foregroundStyle(.secondary)
                // `env -u`, ikke bare `hf auth login`: HF_HOME og HF_TOKEN_PATH
                // flytter fila kommandoen skriver, og appen har fjernet veien
                // til den. Uten dette kan kommandoen lykkes og appen likevel
                // ikke finne noe. Se hfLoginCommand.
                command(AppSettings.hfLoginCommand)
                if LegacyKeychain.hasOrphanedToken {
                    Text("En eldre versjon la et token i nøkkelringen. Det brukes "
                         + "ikke lenger, og blir liggende til du fjerner det:")
                        .font(.caption).foregroundStyle(.secondary)
                    command(LegacyKeychain.removeCommand)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func command(_ text: String) -> some View {
        HStack(alignment: .top) {
            Text(text).font(.caption.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            CopyButton(text: text)
        }
    }
}
