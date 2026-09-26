// Read-only. Only the SHA256 of this output leaves the server-side pipeline.
// Live read/like counters are omitted; no collection is written or restored.
const names = ['posts', 'notes', 'pages', 'categories', 'topics', 'comments', 'links', 'says', 'snippets', 'recentlies']
const databases = db.adminCommand({ listDatabases: 1, nameOnly: true }).databases
  .map((entry) => entry.name).filter((name) => !['admin', 'config', 'local'].includes(name)).sort()
for (const name of databases) {
  const database = db.getSiblingDB(name)
  const existing = database.getCollectionNames()
  for (const collection of names) {
    if (!existing.includes(collection)) continue
    print(name + '/' + collection)
    database.getCollection(collection).find({}, { count: 0 }).sort({ _id: 1 })
      .forEach((doc) => print(EJSON.stringify(doc)))
  }
}
