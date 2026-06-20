// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeData
import EdgeDataMeshBridge
import GRDB

enum EdgeDataBootstrap {

    static func setup() {
        guard !isReady else { return }
        do {
            let dbURL = documentsURL().appendingPathComponent("edge_data.sqlite")
            let dbQueue = try DatabaseQueue(path: dbURL.path)

            var migrator = DatabaseMigrator()
            V2APrimitiveTables.register(&migrator)
            V3ClassificationLifecycle.register(&migrator)
            V5RetryFields.register(&migrator)
            try migrator.migrate(dbQueue)

            let sink = try? EdgeMeshTrainingSink()

            Edge.bootstrap(dbQueue: dbQueue, trainingDataSink: sink)
            trainingSink = sink

            ScaffoldDemoSchema.register()
            ScaffoldSampleDomainRegistry.registerSchemas()
            ScaffoldSampleDomainRegistry.registerSelectedTools()

            isReady = true
            NSLog("[EdgeDataBootstrap] setup complete, db=\(dbURL.lastPathComponent), sink=\(sink == nil ? "nil" : "ok")")
        } catch {
            NSLog("[EdgeDataBootstrap] setup failed: \(error.localizedDescription) — EdgeData 功能不可用")
        }
    }

    private(set) static var isReady = false

    private(set) static var trainingSink: EdgeMeshTrainingSink?


    private static func documentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
    }


}
