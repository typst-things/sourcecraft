use std::fmt;

/// Comportamento comum
pub trait Alimentavel {
    fn comer(&mut self, comida: &Comida) -> u32;
    fn dormir(&self) {
        println!("zzz");
    }
}

pub trait Animal: Alimentavel {
    const PATAS: u8;
    fn nome(&self) -> &str;
    fn novo(nome: String) -> Self where Self: Sized;
}

#[derive(Debug, Clone)]
pub enum Porte {
    Pequeno,
    Medio = 2,
    Grande { peso: f32 },
}

pub struct Comida {
    pub calorias: u32,
}
