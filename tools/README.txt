plink.exe — PuTTY 0.85 (64-bit)
================================

Зачем он здесь:
  Установщик использует plink для входа на сервер по паролю root.
  Встроенный Windows OpenSSH не умеет принимать пароль из файла,
  поэтому для парольного входа нужен plink.

Источник:
  https://the.earth.li/~sgtatham/putty/latest/w64/plink.exe

Лицензия:
  PuTTY распространяется по лицензии MIT.
  Полный текст: https://www.chiark.greenend.org.uk/~sgtatham/putty/licence.html

Установщик при каждом запуске проверяет SHA-256 и подпись plink.exe.
Если файл повреждён или подменён — установка не начнётся.
