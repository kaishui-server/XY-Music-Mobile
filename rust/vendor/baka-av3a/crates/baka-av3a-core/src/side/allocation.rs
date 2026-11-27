use super::McSide;
use crate::Error;

/// Integer arithmetic intentionally truncates signed division toward zero.
pub(super) fn allocate(total: usize, mode: &McSide, lfe_bytes: usize) -> Result<Vec<usize>, Error> {
    let lfe = lfe_bytes != 0;
    let active = mode.ratios.len();
    let fixed = mode.silent.iter().filter(|&&s| s).count() * 8 + lfe_bytes;
    let budget = total
        .checked_sub(fixed)
        .ok_or(Error::Invalid("fixed channel budget"))?;
    if active == 0 || budget < active * 8 || total > 32767 {
        return Err(Error::Invalid("active channel budget"));
    }
    let spare = (budget - active * 8) as i32;
    let mut values: Vec<i32> = mode
        .ratios
        .iter()
        .map(|&r| i32::from(r) * spare / 64 + 8)
        .collect();
    let largest = values
        .iter()
        .enumerate()
        .max_by_key(|&(i, v)| (*v, std::cmp::Reverse(i)))
        .unwrap()
        .0;
    let difference = values.iter().sum::<i32>() - budget as i32;
    if difference != 0 {
        for (v, &r) in values.iter_mut().zip(&mode.ratios) {
            *v = (*v - difference * i32::from(r) / 64).max(8);
        }
    }
    let residue = budget as i32 - values.iter().sum::<i32>();
    values[largest] += residue;
    let mut capped = vec![false; active];
    let mut ratio_sum: i32 = mode.ratios.iter().map(|&v| i32::from(v)).sum();
    for _ in 0..active {
        let Some(index) = (0..active).find(|&i| values[i] > 682 && !capped[i]) else {
            break;
        };
        let excess = values[index] - 682;
        values[index] = 682;
        capped[index] = true;
        ratio_sum -= i32::from(mode.ratios[index]);
        if ratio_sum == 0 {
            return Err(Error::Invalid("channel redistribution ratios"));
        }
        let mut assigned = 0;
        for i in 0..active {
            if !capped[i] {
                let extra = i32::from(mode.ratios[i]) * excess / ratio_sum;
                values[i] += extra;
                assigned += extra;
            }
        }
        values[largest] += excess - assigned;
    }
    // Redistribution residues return to the original largest channel, even
    // after it was capped. The wire allocation can therefore exceed 682 bytes.
    if values.iter().any(|&v| !(8..=32767).contains(&v)) {
        return Err(Error::Invalid("channel entropy budget"));
    }
    let mut values = values.into_iter();
    let result: Vec<usize> = mode
        .silent
        .iter()
        .enumerate()
        .map(|(i, &s)| {
            if lfe && i == 3 {
                lfe_bytes
            } else if s {
                8
            } else {
                values.next().unwrap() as usize
            }
        })
        .collect();
    if result.iter().sum::<usize>() != total {
        return Err(Error::Invalid("channel budget sum"));
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fixed_silence_lfe_and_impossible_budgets() {
        let mode = McSide {
            silent: vec![false, true, false, false, false, false],
            pairs: vec![],
            ratios: vec![16; 4],
        };
        assert_eq!(allocate(256, &mode, 20).unwrap(), [57, 8, 57, 20, 57, 57]);
        assert!(allocate(59, &mode, 20).is_err());
        let empty = McSide {
            silent: vec![true, true, true, false, true, true],
            pairs: vec![],
            ratios: vec![],
        };
        assert!(allocate(200, &empty, 20).is_err());
        let concentrated = McSide {
            silent: vec![false; 4],
            pairs: vec![],
            ratios: vec![63, 0, 0, 0],
        };
        assert!(allocate(2000, &concentrated, 0).is_err());
    }
}
