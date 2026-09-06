# The feed is not consistently typed: `size` is a number of hectares on fires
# but the word "Small" elsewhere, `sizeFmt` is occasionally an array, and ids
# arrive as both numbers and strings. Every scalar is carried as text and cast
# in SQL, so one oddly-typed field cannot fail a whole shard.
def loose:
  if . == null then null
  elif type == "string" then .
  elif type == "number" or type == "boolean" then tostring
  else tojson end;

# One NDJSON row per GeoJSON feature in a snapshot, tagged with the commit's
# unix time: the moment the snapshot was observed, and the only clock the feed's
# own `created`/`updated` can be checked against.
.features[]?
| .properties as $p
| {
    snapshot_ts: ($ts | tonumber),
    commit: $commit,
    id: ($p.id | loose),
    source_id: ($p.sourceId | loose),
    source_org: ($p.sourceOrg | loose),
    source_feed: ($p.sourceFeed | loose),
    source_title: ($p.sourceTitle | loose),
    source: ($p.source | loose),
    feed_type: ($p.feedType | loose),
    category1: ($p.category1 | loose),
    category2: ($p.category2 | loose),
    status: ($p.status | loose),
    name: ($p.name | loose),
    action: ($p.action | loose),
    statewide: ($p.statewide | loose),
    location: ($p.location | loose),
    created: ($p.created | loose),
    updated: ($p.updated | loose),
    resources: ($p.resources | loose),
    size: ($p.size | loose),
    size_fmt: ($p.sizeFmt | loose),
    magnitude: ($p.magnitude | loose),
    event_id: ($p.eventId | loose),
    ses_id: ($p.sesId | loose),
    esta_id: ($p.estaId | loose),
    cfa_id: ($p.cfaId | loose),
    url: ($p.url | loose),
    css_class: ($p.cssClass | loose),
    suppress: ($p.suppress | loose),
    web_headline: ($p.webHeadline | loose),
    text: ($p.text | loose),
    web_body: ($p.webBody | loose),
    cap_category: ($p.cap.category? | loose),
    cap_event: ($p.cap.event? | loose),
    cap_event_code: ($p.cap.eventCode? | loose),
    cap_urgency: ($p.cap.urgency? | loose),
    cap_severity: ($p.cap.severity? | loose),
    cap_certainty: ($p.cap.certainty? | loose),
    cap_response_type: ($p.cap.responseType? | loose),
    cap_sender_name: ($p.cap.senderName? | loose),
    # A warning carries the incidents it covers; this is the only link between
    # the warning feed and the incident feed.
    incident_ids: [$p.incidentFeatures[]?.properties.id? | loose | select(. != null)],
    geom_type: (.geometry.type? | loose),
    # A GeometryCollection carries the point marker and any warning/fire
    # polygons together; a bare Point has no collection to unwrap.
    lon: (if .geometry.type? == "Point" then .geometry.coordinates[0]
          else ([.geometry.geometries[]? | select(.type == "Point") | .coordinates[0]] | first) end),
    lat: (if .geometry.type? == "Point" then .geometry.coordinates[1]
          else ([.geometry.geometries[]? | select(.type == "Point") | .coordinates[1]] | first) end),
    n_polygons: ([.geometry.geometries[]? | select(.type == "Polygon" or .type == "MultiPolygon")] | length),
    geometry: (.geometry | tojson)
  }
