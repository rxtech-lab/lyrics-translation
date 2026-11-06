export default {
  id: '002-publications',
  statements: [
    'CREATE TABLE IF NOT EXISTS publications(owner TEXT NOT NULL, document_id TEXT NOT NULL, share TEXT NOT NULL REFERENCES shares(id), PRIMARY KEY(owner,document_id))',
  ],
};
