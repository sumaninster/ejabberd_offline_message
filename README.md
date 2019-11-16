./autogen.sh
rm -rf deps ; rm -rf _build
./configure --enable-user=ejabberd --enable-all --enable-latest-deps
make
make install