// Payload CMS MongoDB read-only audit helper.
// Usage: mongosh "$MONGODB_URI" scripts/payload-cms-mongo-audit.js
// Run against staging or with a read-only user first. This script prints metadata only.

function section(title) {
  print('\n## ' + title);
}

function safeStats(name) {
  try {
    const s = db.getCollection(name).stats({ scale: 1024 * 1024 });
    return {
      collection: name,
      count: s.count,
      sizeMB: Math.round((s.size || 0) * 100) / 100,
      storageSizeMB: Math.round((s.storageSize || 0) * 100) / 100,
      totalIndexSizeMB: Math.round((s.totalIndexSize || 0) * 100) / 100,
      avgObjSize: s.avgObjSize || 0,
    };
  } catch (e) {
    return { collection: name, error: String(e) };
  }
}

function safeIndexes(name) {
  try {
    return db.getCollection(name).getIndexes().map(i => ({ name: i.name, key: i.key, unique: !!i.unique, sparse: !!i.sparse }));
  } catch (e) {
    return [{ error: String(e) }];
  }
}

const names = db.getCollectionNames().filter(n => !n.startsWith('system.')).sort();
section('Database inventory');
printjson({ db: db.getName(), collections: names.length, names });

section('Collection stats');
printjson(names.map(safeStats));

section('Indexes');
for (const name of names) {
  print('\n### ' + name);
  printjson(safeIndexes(name));
}

section('Potential Payload collections');
const payloadish = names.filter(n => !['payload-preferences', 'payload-migrations', 'payload-locked-documents'].includes(n));
printjson(payloadish.map(name => {
  const c = db.getCollection(name);
  const one = c.findOne({}, { projection: { _id: 1, createdAt: 1, updatedAt: 1, filename: 1, filesize: 1, mimeType: 1, email: 1, tenant: 1, owner: 1, status: 1, _status: 1 } });
  return { collection: name, sampleShape: one };
}));

section('Jobs queue summary');
const jobNames = names.filter(n => /job|queue|task/i.test(n));
for (const name of jobNames) {
  const c = db.getCollection(name);
  print('\n### ' + name);
  try {
    printjson({
      count: c.estimatedDocumentCount(),
      byState: c.aggregate([{ $group: { _id: '$state', count: { $sum: 1 } } }, { $sort: { count: -1 } }]).toArray(),
      byStatus: c.aggregate([{ $group: { _id: '$status', count: { $sum: 1 } } }, { $sort: { count: -1 } }]).toArray(),
      recent: c.find({}, { projection: { taskSlug: 1, workflowSlug: 1, state: 1, status: 1, attempts: 1, error: 1, createdAt: 1, updatedAt: 1 } }).sort({ updatedAt: -1 }).limit(10).toArray(),
    });
  } catch (e) { printjson({ error: String(e) }); }
}

section('Upload/file-like summary');
const fileLike = names.filter(name => {
  try { return !!db.getCollection(name).findOne({ $or: [{ filename: { $exists: true } }, { mimeType: { $exists: true } }, { filesize: { $exists: true } }] }); }
  catch (e) { return false; }
});
for (const name of fileLike) {
  const c = db.getCollection(name);
  print('\n### ' + name);
  try {
    printjson({
      count: c.estimatedDocumentCount(),
      totalFilesizeBytes: c.aggregate([{ $group: { _id: null, bytes: { $sum: '$filesize' } } }]).toArray(),
      byMime: c.aggregate([{ $group: { _id: '$mimeType', count: { $sum: 1 }, bytes: { $sum: '$filesize' } } }, { $sort: { count: -1 } }, { $limit: 20 }]).toArray(),
      largest: c.find({}, { projection: { filename: 1, mimeType: 1, filesize: 1, createdAt: 1, updatedAt: 1 } }).sort({ filesize: -1 }).limit(10).toArray(),
    });
  } catch (e) { printjson({ error: String(e) }); }
}
