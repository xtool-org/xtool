import WidgetKit
import SwiftUI

@main struct Bundle: WidgetBundle {
    var body: some Widget {
        DemoWidget()
    }
}

struct DemoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "DemoWidget",
            provider: Provider()
        ) { entry in
            VStack {
                Text(entry.date, style: .date)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("DemoWidget")
        .description("This is an example widget.")
    }

    struct Entry: TimelineEntry {
        var date = Date()
    }

    struct Provider: TimelineProvider {
        func placeholder(in context: Context) -> Entry {
            Entry()
        }

        func getSnapshot(
            in context: Context,
            completion: @escaping (Entry) -> Void
        ) {
            completion(Entry())
        }

        func getTimeline(
            in context: Context,
            completion: @escaping (Timeline<Entry>) -> Void
        ) {
            completion(Timeline(
                entries: [Entry()],
                policy: .after(.now + 3600)
            ))
        }
    }
}
