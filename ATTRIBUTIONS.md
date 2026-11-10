# Adult-content blocklist attribution

`Resources/adult-domains.txt` is shipped with Mastbound. It is a merge of
adult-domain sources mirrored by
[StevenBlack/hosts](https://github.com/StevenBlack/hosts) (MIT) at revision
`92a38fd106abe49f50ed6904ff0e867f4eb44f9f`, built by `script/make-list.sh`
(76,744 domains, SHA-256
`6113a8bd81f45149e586f23e5cb33b03a5a24ef9d32d196877c54dd333d2f0b3`).

| Source | Homepage | License |
| --- | --- | --- |
| BigDargon hostsVN adult | https://github.com/bigdargon/hostsVN | MIT |
| brijrajparmar27 pornography | https://github.com/brijrajparmar27/host-sources | CC BY 4.0 |
| Clefspeare13 pornhosts | https://github.com/Clefspeare13/pornhosts | MIT |
| Sinfonietta snuff-site list | https://github.com/Sinfonietta/hostfiles | MIT |
| Sinfonietta pornography list | https://github.com/Sinfonietta/hostfiles | MIT |
| Tiuxo pornography list | https://github.com/tiuxo/hosts | CC BY 4.0 |

The list was changed from the sources: entries were merged, lowercased,
deduplicated, sorted, and names that are not valid exact domains were
removed. List inclusion does not mean every entry is correct.

TODO before a public release: include the full MIT license notices of each
MIT source and of StevenBlack/hosts in the app bundle (see P5).
