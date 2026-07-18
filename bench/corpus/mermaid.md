# Mermaid-heavy corpus

Deterministic fixture for the perf gate: mermaid fences must lay out as skeletons with zero rasterization cost on the first-paint path.


## Section 0

The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. 

```mermaid
graph TD
    A[Request arrives] --> B{Cache hit?}
    B -->|Yes| C[Serve raster 0]
    B -->|No| D[Queue render 0]
    D --> E[Snapshot webview]
    E --> F[Upload texture]
    F --> C
```

Interleaved prose keeps block shapes realistic. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. 

```swift
func measure0() -> Double {
    let start = CACurrentMediaTime()
    defer { record(CACurrentMediaTime() - start, slot: 0) }
    return layout.prepare(docRange: visible, anchorY: top)
}
```


## Section 1

The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. 

```mermaid
sequenceDiagram
    participant V as Viewer1
    participant S as Session
    participant R as Renderer
    V->>S: requestDiagrams(visible)
    S->>R: renderDiagram(source 1)
    R-->>S: DiagramImage
    S-->>V: onDiagramReady(1)
```

Interleaved prose keeps block shapes realistic. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. 

```swift
func measure1() -> Double {
    let start = CACurrentMediaTime()
    defer { record(CACurrentMediaTime() - start, slot: 1) }
    return layout.prepare(docRange: visible, anchorY: top)
}
```


## Section 2

The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. 

```mermaid
pie title Frame budget 2
    "Layout" : 42
    "Encode" : 33
    "Present" : 25
```

Interleaved prose keeps block shapes realistic. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. 

```swift
func measure2() -> Double {
    let start = CACurrentMediaTime()
    defer { record(CACurrentMediaTime() - start, slot: 2) }
    return layout.prepare(docRange: visible, anchorY: top)
}
```


## Section 3

The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. 

```mermaid
graph TD
    A[Request arrives] --> B{Cache hit?}
    B -->|Yes| C[Serve raster 3]
    B -->|No| D[Queue render 3]
    D --> E[Snapshot webview]
    E --> F[Upload texture]
    F --> C
```

Interleaved prose keeps block shapes realistic. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. 

```swift
func measure3() -> Double {
    let start = CACurrentMediaTime()
    defer { record(CACurrentMediaTime() - start, slot: 3) }
    return layout.prepare(docRange: visible, anchorY: top)
}
```


## Section 4

The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. 

```mermaid
sequenceDiagram
    participant V as Viewer4
    participant S as Session
    participant R as Renderer
    V->>S: requestDiagrams(visible)
    S->>R: renderDiagram(source 4)
    R-->>S: DiagramImage
    S-->>V: onDiagramReady(4)
```

Interleaved prose keeps block shapes realistic. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. 

```swift
func measure4() -> Double {
    let start = CACurrentMediaTime()
    defer { record(CACurrentMediaTime() - start, slot: 4) }
    return layout.prepare(docRange: visible, anchorY: top)
}
```


## Section 5

The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. 

```mermaid
pie title Frame budget 5
    "Layout" : 45
    "Encode" : 30
    "Present" : 25
```

Interleaved prose keeps block shapes realistic. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. 

```swift
func measure5() -> Double {
    let start = CACurrentMediaTime()
    defer { record(CACurrentMediaTime() - start, slot: 5) }
    return layout.prepare(docRange: visible, anchorY: top)
}
```


## Section 6

The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. 

```mermaid
graph TD
    A[Request arrives] --> B{Cache hit?}
    B -->|Yes| C[Serve raster 6]
    B -->|No| D[Queue render 6]
    D --> E[Snapshot webview]
    E --> F[Upload texture]
    F --> C
```

Interleaved prose keeps block shapes realistic. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. 

```swift
func measure6() -> Double {
    let start = CACurrentMediaTime()
    defer { record(CACurrentMediaTime() - start, slot: 6) }
    return layout.prepare(docRange: visible, anchorY: top)
}
```


## Section 7

The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. 

```mermaid
sequenceDiagram
    participant V as Viewer7
    participant S as Session
    participant R as Renderer
    V->>S: requestDiagrams(visible)
    S->>R: renderDiagram(source 7)
    R-->>S: DiagramImage
    S-->>V: onDiagramReady(7)
```

Interleaved prose keeps block shapes realistic. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. 

```swift
func measure7() -> Double {
    let start = CACurrentMediaTime()
    defer { record(CACurrentMediaTime() - start, slot: 7) }
    return layout.prepare(docRange: visible, anchorY: top)
}
```


## Section 8

The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. 

```mermaid
pie title Frame budget 8
    "Layout" : 48
    "Encode" : 27
    "Present" : 25
```

Interleaved prose keeps block shapes realistic. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. 

```swift
func measure8() -> Double {
    let start = CACurrentMediaTime()
    defer { record(CACurrentMediaTime() - start, slot: 8) }
    return layout.prepare(docRange: visible, anchorY: top)
}
```


## Section 9

The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. 

```mermaid
graph TD
    A[Request arrives] --> B{Cache hit?}
    B -->|Yes| C[Serve raster 9]
    B -->|No| D[Queue render 9]
    D --> E[Snapshot webview]
    E --> F[Upload texture]
    F --> C
```

Interleaved prose keeps block shapes realistic. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. 

```swift
func measure9() -> Double {
    let start = CACurrentMediaTime()
    defer { record(CACurrentMediaTime() - start, slot: 9) }
    return layout.prepare(docRange: visible, anchorY: top)
}
```


## Section 10

The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. 

```mermaid
sequenceDiagram
    participant V as Viewer10
    participant S as Session
    participant R as Renderer
    V->>S: requestDiagrams(visible)
    S->>R: renderDiagram(source 10)
    R-->>S: DiagramImage
    S-->>V: onDiagramReady(10)
```

Interleaved prose keeps block shapes realistic. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. 

```swift
func measure10() -> Double {
    let start = CACurrentMediaTime()
    defer { record(CACurrentMediaTime() - start, slot: 10) }
    return layout.prepare(docRange: visible, anchorY: top)
}
```


## Section 11

The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. 

```mermaid
pie title Frame budget 11
    "Layout" : 51
    "Encode" : 24
    "Present" : 25
```

Interleaved prose keeps block shapes realistic. The renderer keeps the skeleton on glass until the raster lands; the anchored swap means content never jumps while you read. Each diagram below exercises the pending-diagram path at first paint — the gate holds this corpus to the same first-pixel ceiling as plain markdown, which is the whole point: diagram work must never buy its pixels with launch latency. 

```swift
func measure11() -> Double {
    let start = CACurrentMediaTime()
    defer { record(CACurrentMediaTime() - start, slot: 11) }
    return layout.prepare(docRange: visible, anchorY: top)
}
```

