pub mod interfaces {
    pub mod IERC20;
    pub mod IVE;
}

//#[cfg(test)]
pub mod mocks {
    pub mod erc20;
}

mod velords;

#[cfg(test)]
mod tests {
    pub mod common;
    mod test_velords;
}
