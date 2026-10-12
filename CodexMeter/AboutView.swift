import AppKit
import SwiftUI

struct AboutView: View {
    var embedded = false
    @Environment(\.dismiss) private var dismiss

    private let repositoryURL = URL(string: "https://github.com/raycalrui/CodexMeter")!

    private var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private var installedBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    var body: some View {
        VStack(spacing: 0) {
            if !embedded {
                header
                Divider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    identitySection
                    privacySection
                    licenseSection
                }
                .padding(18)
            }
        }
        .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack {
            Label(L10n.string("about.title"), systemImage: "info.circle")
                .font(.headline)
            Spacer()
            Button(L10n.string("action.close")) { dismiss() }
        }
        .padding(16)
    }

    private var identitySection: some View {
        GroupBox {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 5) {
                    Text("CodexMeter").font(.title2.weight(.semibold))
                    Text(L10n.format(
                        "about.version_format",
                        installedVersion,
                        installedBuild
                    ))
                    .foregroundStyle(.secondary)
                    Link(destination: repositoryURL) {
                        Label(L10n.string("about.github"), systemImage: "link")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var privacySection: some View {
        GroupBox(L10n.string("about.privacy")) {
            Text(L10n.string("about.privacy_description"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    private var licenseSection: some View {
        GroupBox(L10n.string("about.license")) {
            Text(L10n.string("about.license_undeclared"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }
}
