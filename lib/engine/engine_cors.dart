// ============================================================================
//  engine_cors.dart — CORS preflight of `@Page(cors: true)` routes
//  (part of engine.dart; the public API stays on [Engine]).
// ============================================================================

part of 'engine.dart';

Future<void> _preflightWithGate(HttpHeaders h, Page meta, String? origin, String? headerValues, Uri uri) async {
  if (origin == null || origin.isEmpty) return;
  final gate = Engine.preflightOrigin;
  if (gate != null && !await gate(origin, uri)) return;
  _preflight(h, meta, origin, headerValues);
}

void _preflight(HttpHeaders h, Page meta, String? origin, String? headerValues) {
  if (origin == null || origin.isEmpty) return;
  h.set('Access-Control-Allow-Origin', origin);
  h.set('Access-Control-Allow-Methods', [...(meta.methods.isEmpty ? const ['GET', 'POST'] : meta.methods), 'OPTIONS'].join(', '));
  if (headerValues != null && headerValues.isNotEmpty) h.set('Access-Control-Allow-Headers', headerValues);
  h.set('Access-Control-Max-Age', '86400');
  h.set('Vary', 'Origin');
}
