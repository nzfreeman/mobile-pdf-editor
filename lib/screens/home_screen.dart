import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../services/drive_service.dart';
import 'pdf_editor_screen.dart';

class HomeScreen extends StatefulWidget { const HomeScreen({super.key}); @override State<HomeScreen> createState()=>_HomeScreenState(); }
class _HomeScreenState extends State<HomeScreen> {
  final _drive=DriveService(); bool _busy=false;
  Future<void> _open(File file,String name) async => Navigator.push(context,MaterialPageRoute(builder:(_)=>PdfEditorScreen(pdfFile:file,fileName:name)));
  Future<void> _pickLocal() async {setState(()=>_busy=true);try{final r=await FilePicker.platform.pickFiles(type:FileType.custom,allowedExtensions:['pdf']);final p=r?.files.single.path;if(p!=null&&mounted)await _open(File(p),r!.files.single.name);}finally{if(mounted)setState(()=>_busy=false);}}
  Future<void> _pickDrive() async {setState(()=>_busy=true);try{final files=await _drive.listPdfFiles();if(!mounted)return;final selected=await showDialog<DrivePdfFile>(context:context,builder:(_)=>AlertDialog(title:const Text('Google Drive PDF'),content:SizedBox(width:420,height:420,child:files.isEmpty?const Center(child:Text('PDF가 없습니다.')):ListView.builder(itemCount:files.length,itemBuilder:(_,i)=>ListTile(leading:const Icon(Icons.picture_as_pdf),title:Text(files[i].name),onTap:()=>Navigator.pop(context,files[i])))),actions:[TextButton(onPressed:()=>Navigator.pop(context),child:const Text('취소'))]));if(selected!=null){final file=await _drive.download(selected);if(mounted)await _open(file,selected.name);}}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Drive 열기 실패: $e')));}finally{if(mounted)setState(()=>_busy=false);}}
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Mobile PDF Editor')),body:Center(child:Padding(padding:const EdgeInsets.all(28),child:Column(mainAxisSize:MainAxisSize.min,children:[Icon(Icons.picture_as_pdf,size:96,color:Theme.of(context).colorScheme.primary),const SizedBox(height:20),Text('PDF 편집기',style:Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight:FontWeight.bold)),const SizedBox(height:8),const Text('다중 페이지 · 자유 필기 · 사진 · 도장 · 실행 취소 · Google Drive',textAlign:TextAlign.center),const SizedBox(height:28),FilledButton.icon(onPressed:_busy?null:_pickLocal,icon:const Icon(Icons.folder_open),label:const Text('기기에서 PDF 열기')),const SizedBox(height:12),OutlinedButton.icon(onPressed:_busy?null:_pickDrive,icon:const Icon(Icons.cloud),label:const Text('Google Drive에서 열기')),if(_busy)...[const SizedBox(height:20),const CircularProgressIndicator()]]))));
}
