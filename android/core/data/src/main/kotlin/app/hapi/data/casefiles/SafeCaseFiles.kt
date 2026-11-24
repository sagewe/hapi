package app.hapi.data.casefiles

import java.io.File
import java.io.RandomAccessFile
import java.util.zip.ZipFile
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

fun safeCaseName(name: String): String {
    val cleaned = name.substringAfterLast('/').substringAfterLast('\\')
        .replace(Regex("[\\p{Cntrl}:*?\"<>|]"), "_").trim().trim('.').ifBlank { "资料" }
    val extension = cleaned.substringAfterLast('.', "").takeIf { it.length in 1..12 }?.let { ".$it" }.orEmpty()
    val stem = cleaned.removeSuffix(extension)
    val shortened = buildString {
        var bytes = extension.toByteArray(Charsets.UTF_8).size
        for (codePoint in stem.codePoints().toArray()) {
            val chunk = String(Character.toChars(codePoint))
            bytes += chunk.toByteArray(Charsets.UTF_8).size
            if (bytes > 180) break
            append(chunk)
        }
    }
    return shortened.ifBlank { "资料" } + extension
}
fun needsSelectionZip(mimeTypes: List<String>): Boolean = mimeTypes.size > 1 && !mimeTypes.all { it.startsWith("image/") }
fun selectionZipName(caseName: String, count: Int) = "${safeCaseName(caseName).take(60)}_精选资料(${count}份).zip"

/** Validate the central directory BEFORE Java opens or inflates any member. */
class SafeCaseZip(private val archive: File) {
    data class Member(val name: String, val size: Long)
    val members: List<Member>
    init {
        require(archive.length() <= MAX_TOTAL) { "压缩包超过 100 MB" }
        members = RandomAccessFile(archive, "r").use { f ->
            fun u16(): Int = f.readUnsignedByte() or (f.readUnsignedByte() shl 8)
            fun u32(): Long = u16().toLong() or (u16().toLong() shl 16)
            var end = f.length() - 22
            val lower = maxOf(0L, f.length() - 65557)
            while (end >= lower) { f.seek(end); if (u32() == 0x06054b50L && run { f.seek(end + 20); u16().toLong() == f.length() - end - 22 }) break; end-- }
            require(end >= lower) { "无法读取 ZIP 目录" }
            f.seek(end + 4); require(u16() == 0 && u16() == 0) { "不支持分卷 ZIP" }
            val diskCount = u16(); val count = u16(); require(count == diskCount && count <= 500) { "ZIP 条目超过限制" }
            val directorySize = u32(); val offset = u32(); require(offset + directorySize <= end) { "ZIP 目录无效" }
            f.seek(offset)
            var total = 0L
            val seen = mutableSetOf<String>()
            buildList {
                repeat(count) {
                    require(u32() == 0x02014b50L) { "ZIP 条目无效" }
                    val creator = u16(); u16(); val flags = u16(); val method = u16()
                    require(flags and 0x41 == 0) { "加密 ZIP 请先在电脑解密后送审" }
                    require(method == 0 || method == 8) { "不支持此 ZIP 压缩方式" }
                    f.skipBytes(8); val compressed = u32(); val size = u32()
                    val nameLength = u16(); val extra = u16(); val comment = u16(); val disk = u16(); u16(); val attrs = u32(); val local = u32()
                    require(disk == 0 && local < offset) { "ZIP 索引无效" }
                    val bytes = ByteArray(nameLength); f.readFully(bytes)
                    val name = bytes.toString(if (flags and 0x800 != 0) Charsets.UTF_8 else charset("CP437"))
                    require(name.isNotEmpty() && !name.startsWith('/') && !name.contains('\\') && !name.contains(':') && name.none { it.code < 32 } && name.split('/').none { it == ".." || it == "." }) { "ZIP 含不安全路径" }
                    require(seen.add(name)) { "ZIP 含重名条目" }
                    val unixType = (attrs shr 16).toInt() and 0xf000
                    require(creator shr 8 != 3 || unixType == 0 || unixType == 0x8000 || unixType == 0x4000) { "ZIP 不允许符号链接或特殊文件" }
                    total += size
                    require(size <= MAX_FILE && total <= MAX_TOTAL && size <= maxOf(1L, compressed) * 200) { "ZIP 解压体积或压缩比超过限制" }
                    f.skipBytes(extra + comment)
                    if (!name.endsWith('/') && name.split('/').none { it == "__MACOSX" || it.startsWith("._") }) add(Member(name, size))
                }
                require(f.filePointer == offset + directorySize) { "ZIP 目录长度无效" }
            }
        }
    }
    fun extract(member: Member, directory: File): File {
        require(member in members)
        directory.mkdirs()
        val target = File(directory, safeCaseName(member.name))
        try {
            ZipFile(archive).use { zip ->
                val entry = requireNotNull(zip.getEntry(member.name))
                val crc = java.util.zip.CRC32()
                zip.getInputStream(entry).use { input -> target.outputStream().use { output ->
                    val buffer = ByteArray(8192); var total = 0L
                    while (true) { val n = input.read(buffer); if (n < 0) break
                        total += n; require(total <= member.size && total <= MAX_FILE) { "ZIP 解压超过限制" }; crc.update(buffer,0,n); output.write(buffer,0,n)
                    }
                    require(total == member.size && crc.value == entry.crc) { "ZIP 校验失败" }
                } }
            }
            return target
        } catch (e: Exception) { target.delete(); throw e }
    }
    companion object { const val MAX_FILE = 50L * 1024 * 1024; const val MAX_TOTAL = 100L * 1024 * 1024 }
}
fun packageSelection(files: List<File>, target: File): File {
    require(files.isNotEmpty() && files.size <= 500)
    var total = 0L
    ZipOutputStream(target.outputStream()).use { zip ->
        val used = mutableSetOf<String>()
        files.forEachIndexed { index, file ->
            total += file.length(); require(total <= SafeCaseZip.MAX_TOTAL) { "所选资料超过 100 MB，请分批转发" }
            var name = safeCaseName(file.name); if (!used.add(name)) { name = "${index + 1}_$name"; check(used.add(name)) }
            zip.putNextEntry(ZipEntry(name)); file.inputStream().use { it.copyTo(zip) }; zip.closeEntry()
        }
    }
    return target
}
