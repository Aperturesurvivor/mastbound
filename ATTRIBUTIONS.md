# Adult-content blocklist attribution

`Resources/adult-domains.txt` is shipped with Mastbound. It is a merge of
adult-domain sources mirrored by
[StevenBlack/hosts](https://github.com/StevenBlack/hosts) (MIT) at revision
`92a38fd106abe49f50ed6904ff0e867f4eb44f9f`, built by `script/make-list.sh`
(63,312 domains, SHA-256
`db929b125e7991f5127e278377f69bb860fa753450580d7593ae6ea58a9533bc`).

| Source | Homepage | License |
| --- | --- | --- |
| BigDargon hostsVN adult | https://github.com/bigdargon/hostsVN | MIT |
| Sinfonietta snuff-site list | https://github.com/Sinfonietta/hostfiles | MIT |
| Sinfonietta pornography list | https://github.com/Sinfonietta/hostfiles | MIT |
| Tiuxo pornography list | https://github.com/tiuxo/hosts | CC BY 4.0 |

The list was changed from the sources: entries were merged, lowercased,
deduplicated, sorted, and names that are not valid exact domains were
removed. List inclusion does not mean every entry is correct.

License texts are in `Resources/licenses/` and must ship with the list:

| File | For |
| --- | --- |
| `StevenBlack-hosts.txt` | StevenBlack/hosts (MIT), revision above |
| `bigdargon-hostsVN.txt` | BigDargon hostsVN (MIT) |
| `Sinfonietta-hostfiles.txt` | both Sinfonietta lists (MIT) |
| `tiuxo-hosts.txt` | Tiuxo (CC BY 4.0) |

Not used (decision D6, 2026-11-16): Clefspeare13 pornhosts (its repository is
blocked by GitHub, so its license notice cannot be read) and brijrajparmar27
(no license file). Every source above has a license text in this repo.
