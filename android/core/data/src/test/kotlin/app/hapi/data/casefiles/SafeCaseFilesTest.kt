package app.hapi.data.casefiles
import java.io.File
import java.nio.file.Files
import java.util.zip.*
import org.junit.Test
import org.junit.Assert.*
class SafeCaseFilesTest {
 private fun zip(name: String="合同.txt",data: ByteArray="hello".toByteArray()): File = Files.createTempFile("case-", ".zip").toFile().apply { deleteOnExit();ZipOutputStream(outputStream()).use { it.putNextEntry(ZipEntry(name));it.write(data);it.closeEntry() } }
 private fun mutate(file: File, change: (ByteArray,Int) -> Unit): File { val b=file.readBytes();val i=(0..b.size-4).first { b[it]==0x50.toByte() && b[it+1]==0x4b.toByte() && b[it+2]==1.toByte() && b[it+3]==2.toByte() };change(b,i);file.writeBytes(b);return file }
 private fun rejected(file: File) { try { SafeCaseZip(file);fail("unsafe ZIP accepted") } catch (_: IllegalArgumentException) {} }
 @Test fun traversalRejected() { listOf("../secret","a/../../secret","/absolute","C:/win","a\\bad").forEach { rejected(zip(it)) } }
 @Test fun encryptedRejected() { rejected(mutate(zip()) { b,i->b[i+8]=(b[i+8].toInt() or 1).toByte() }) }
 @Test fun linksRejected() { rejected(mutate(zip()) { b,i->b[i+5]=3;b[i+41]=0xa1.toByte() }) }
 @Test fun bombRejected() { rejected(zip(data=ByteArray(1024*1024))) }
 @Test fun oversizedDeclarationRejected() { rejected(mutate(zip()) { b,i->b[i+27]=0x7f }) }
 @Test fun ignoresMacMetadata() { assertTrue(SafeCaseZip(zip("__MACOSX/junk")).members.isEmpty()) }
 @Test fun roundTripAndCRC() { val file=zip();val safe=SafeCaseZip(file);val dir=Files.createTempDirectory("case-out").toFile();assertEquals("hello",safe.extract(safe.members.single(),dir).readText());dir.deleteRecursively() }
 @Test fun selectedSharingRoute() { assertFalse(needsSelectionZip(listOf("image/png","image/jpeg")));assertTrue(needsSelectionZip(listOf("application/pdf","image/png")));assertTrue(needsSelectionZip(listOf("application/pdf","application/pdf")));assertFalse(needsSelectionZip(listOf("application/pdf"))) }
 @Test fun safeSaveNames() { assertEquals("报告.pdf",safeCaseName("../../报告.pdf"));assertEquals("资料",safeCaseName(".."));assertFalse(safeCaseName("a\nb:?.txt").contains('\n'));assertEquals("案件_精选资料(2份).zip",selectionZipName("../案件",2)) }
 @Test fun longChineseNamesRemainWritableAndKeepExtension() {
  val name=safeCaseName("合成单据😀".repeat(60)+".pdf");assertTrue(name.toByteArray(Charsets.UTF_8).size <= 180);assertTrue(name.endsWith(".pdf"))
  val dir=Files.createTempDirectory("long-name").toFile();File(dir,name).writeText("safe");assertEquals("safe",File(dir,name).readText());dir.deleteRecursively()
 }
 @Test fun packagedDuplicateNamesPreserved() { val a=Files.createTempDirectory("sel-a").toFile();val b=Files.createTempDirectory("sel-b").toFile();val one=File(a,"同名.pdf").apply { writeText("one") };val two=File(b,"同名.pdf").apply { writeText("two") };val output=File(a,"selected.zip");packageSelection(listOf(one,two),output);assertEquals(2,SafeCaseZip(output).members.size);a.deleteRecursively();b.deleteRecursively() }
}
