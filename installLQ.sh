#!/bin/bash

aliasFile=~/.bashrc
touch ~/.bashrc

if grep -q 'if \[ -f ~\/\.bash_aliases ];' ~/.bashrc; then
  aliasFile=~/.bash_aliases
  touch ~/.bash_aliases
fi

mytemp=$(mktemp)
sed '/alias lq=/d' ${aliasFile} > ${mytemp}
echo "alias lq=\"cd '$1' && sudo ./lq\"" >> ${mytemp}
mv ${mytemp} ${aliasFile}


