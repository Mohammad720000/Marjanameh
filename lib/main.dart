
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppDb.instance.init();
  runApp(const MarjNamehApp());
}

class MarjNamehApp extends StatelessWidget {
  const MarjNamehApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'مرجع‌نامه',
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
    home: const HomePage(),
  );
}

class AppDb {
  AppDb._();
  static final instance = AppDb._();
  late Database db;

  Future<void> init() async {
    final base = await getDatabasesPath();
    db = await openDatabase(
      p.join(base, 'marjnameh.db'),
      version: 1,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE documents(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            category TEXT NOT NULL,
            filePath TEXT NOT NULL,
            extractedText TEXT NOT NULL,
            addedAt TEXT NOT NULL
          )
        ''');
      },
    );
  }

  Future<int> insert(Map<String, Object?> row) => db.insert('documents', row);
  Future<List<Map<String, Object?>>> all() =>
      db.query('documents', orderBy: 'addedAt DESC');

  Future<void> delete(int id) async {
    await db.delete('documents', where: 'id=?', whereArgs: [id]);
  }
}

String norm(String s) => s
    .replaceAll('ي', 'ی')
    .replaceAll('ى', 'ی')
    .replaceAll('ك', 'ک')
    .replaceAll('\u200c', ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    .toLowerCase();

class PdfRecord {
  final int id;
  final String title;
  final String category;
  final String path;
  final String text;

  PdfRecord(this.id, this.title, this.category, this.path, this.text);

  factory PdfRecord.fromMap(Map<String, Object?> m) => PdfRecord(
    m['id'] as int,
    m['title'] as String,
    m['category'] as String,
    m['filePath'] as String,
    m['extractedText'] as String,
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final search = TextEditingController();
  List<PdfRecord> docs = [];
  bool busy = false;
  String cat = 'همه';

  @override
  void initState() {
    super.initState();
    load();
    search.addListener(() => setState(() {}));
  }

  Future<void> load() async {
    final rows = await AppDb.instance.all();
    if (mounted) {
      setState(() => docs = rows.map(PdfRecord.fromMap).toList());
    }
  }

  List<PdfRecord> get results {
    final q = norm(search.text);
    return docs.where((d) {
      final ok = cat == 'همه' || d.category == cat;
      return ok &&
          (q.isEmpty ||
              norm(d.title).contains(q) ||
              norm(d.text).contains(q));
    }).toList();
  }

  Future<void> addPdf() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      withData: true,
    );
    if (picked == null || picked.files.single.bytes == null) return;

    setState(() => busy = true);
    try {
      final f = picked.files.single;
      final dir = await getApplicationDocumentsDirectory();
      final store = Directory(p.join(dir.path, 'pdfs'));
      if (!await store.exists()) await store.create(recursive: true);

      final target = File(
        p.join(store.path, '${DateTime.now().millisecondsSinceEpoch}_${f.name}'),
      );
      await target.writeAsBytes(f.bytes!);

      final text = extract(f.bytes!);
      final chosen = await chooseCategory();
      if (chosen == null) {
        await target.delete();
        return;
      }

      await AppDb.instance.insert({
        'title': f.name,
        'category': chosen,
        'filePath': target.path,
        'extractedText': text,
        'addedAt': DateTime.now().toIso8601String(),
      });
      await load();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String extract(Uint8List bytes) {
    final doc = PdfDocument(inputBytes: bytes);
    final b = StringBuffer();
    for (var i = 0; i < doc.pages.count; i++) {
      b.writeln(doc.pages[i].extractText());
      b.writeln('--- صفحه ${i + 1} ---');
    }
    doc.dispose();
    return b.toString();
  }

  Future<String?> chooseCategory() async {
    var v = 'تسهیلات و تعهدات';
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('دسته‌بندی سند'),
        content: StatefulBuilder(
          builder: (c, set) => DropdownButton<String>(
            value: v,
            isExpanded: true,
            items: const [
              DropdownMenuItem(
                value: 'تسهیلات و تعهدات',
                child: Text('تسهیلات و تعهدات'),
              ),
              DropdownMenuItem(value: 'صندوق', child: Text('صندوق')),
              DropdownMenuItem(value: 'فرم‌ها', child: Text('فرم‌ها')),
            ],
            onChanged: (x) => set(() => v = x!),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, v),
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );
  }

  Future<void> remove(PdfRecord d) async {
    await AppDb.instance.delete(d.id);
    final f = File(d.path);
    if (await f.exists()) await f.delete();
    await load();
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('مرجع‌نامه'),
        actions: [
          IconButton(
            onPressed: busy ? null : addPdf,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: search,
              decoration: InputDecoration(
                hintText: 'جست‌وجو در همه PDFها...',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                suffixIcon: search.text.isEmpty
                    ? null
                    : IconButton(
                        onPressed: search.clear,
                        icon: const Icon(Icons.clear),
                      ),
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: ['همه', 'تسهیلات و تعهدات', 'صندوق', 'فرم‌ها']
                  .map((x) => Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: ChoiceChip(
                          label: Text(x),
                          selected: cat == x,
                          onSelected: (_) => setState(() => cat = x),
                        ),
                      ))
                  .toList(),
            ),
          ),
          if (busy) const LinearProgressIndicator(),
          Expanded(
            child: results.isEmpty
                ? const Center(child: Text('سندی پیدا نشد.'))
                : ListView.builder(
                    itemCount: results.length,
                    itemBuilder: (c, i) {
                      final d = results[i];
                      return ListTile(
                        leading: const Icon(Icons.picture_as_pdf),
                        title: Text(d.title),
                        subtitle: Text(d.category),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => remove(d),
                        ),
                        onTap: () => Navigator.push(
                          c,
                          MaterialPageRoute(
                            builder: (_) =>
                                PdfPage(title: d.title, path: d.path),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: busy ? null : addPdf,
        icon: const Icon(Icons.add),
        label: const Text('افزودن PDF'),
      ),
    ),
  );
}

class PdfPage extends StatelessWidget {
  final String title;
  final String path;

  const PdfPage({super.key, required this.title, required this.path});

  @override
  Widget build(BuildContext c) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SfPdfViewer.file(File(path)),
    ),
  );
}
