// VWLayout — lazy block layout (lands in P3).
//
// Pure layoutBlock function; LayoutStore cache (viewport ± 4 screens);
// BlockGeometryTree (Fenwick tree over estimated/exact heights, O(log n) y↔block);
// height estimation; scroll anchoring so estimate corrections above the viewport
// never move visible pixels; auto-table column layout.
