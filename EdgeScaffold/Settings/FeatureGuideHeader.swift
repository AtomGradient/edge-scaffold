// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI

struct FeatureGuideHeader: View {
    let icon: String
    let title: String
    let description: String
    let steps: [Step]
    var developerNote: String? = nil

    struct Step {
        let number: Int
        let action: String
        let api: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.indigo)

            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(steps, id: \.number) { step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(step.number)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(.indigo))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.action)
                                .font(.caption)
                            Text(step.api)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.indigo)
                        }
                    }
                }
            }

            if let note = developerNote {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "hammer.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }
}
